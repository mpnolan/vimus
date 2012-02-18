{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
module Main (main) where

import UI.Curses hiding (wgetch, ungetch, mvaddstr)
import Control.Exception (finally)

import qualified Network.MPD as MPD hiding (withMPD)
import qualified Network.MPD.Commands.Extensions as MPDE
import Network.MPD (withMPD_, Seconds)

import Control.Monad.State (liftIO, gets, get, put, modify, forever, when, runStateT, MonadIO)

import Data.Foldable (forM_)
import Data.List
import Data.Maybe
import Data.IORef
import System.FilePath ((</>))
import System.Directory (doesFileExist)
import System.Environment (getEnv)

import Control.Concurrent

import Text.Printf (printf)

import Prelude hiding (getChar)

import qualified WindowLayout
import qualified Input
import Macro

import ListWidget (ListWidget)
import qualified ListWidget

import qualified PlaybackState
import           PlaybackState (PlaybackState)

import Option (getOptions)
import Util (strip)

import Control.Monad.Loops (whileM_)

import Vimus
import Command (runCommand, search, searchPredicate, filterPredicate, globalCommands, makeListWidget, makeContentListWidget)

import qualified Song
import Content

------------------------------------------------------------------------
-- playlist widget

createListWidget :: (Show a, ListWidget.Searchable a, MonadIO m) => Window -> [a] -> m (ListWidget a)
createListWidget window songs = liftIO $ do
  (viewSize, _) <- getmaxyx window
  return $ ListWidget.new songs viewSize


handlePlaylist :: Handler (ListWidget Content)
handlePlaylist ev l = case ev of
  EvPlaylistChanged -> do
    songs <- MPDE.getPlaylist
    return $ Just $ ListWidget.update l $ map Song songs

  _ -> return Nothing


handleLibrary :: Handler (ListWidget Content)
handleLibrary ev l = case ev of
  EvLibraryChanged -> do
    songs <- MPD.listAllInfo ""
    return $ Just $ ListWidget.update l $ map toContent songs

  _ -> return Nothing

handleBrowser :: Handler (ListWidget Content)
handleBrowser ev l = case ev of
  EvLibraryChanged -> do
    songs <- MPD.lsInfo ""
    return $ Just $ ListWidget.update l $ map toContent songs

  _ -> return Nothing

------------------------------------------------------------------------
-- The main event loop
--

-- | Read file "~/.vimusrc", if it exists.
readVimusRc :: IO [String]
readVimusRc = do
  home <- getEnv "HOME"
  let vimusrc = home </> ".vimusrc"
  f <- doesFileExist vimusrc
  if f then (map strip . lines) `fmap` readFile vimusrc else return []

mainLoop ::  Window -> Chan Notify -> IO Window -> Vimus ()
mainLoop window chan onResize = do

  -- place cursor on current song, if any
  withAllWidgets $ sendEvent EvPlaylistChanged
  st <- MPD.status
  case MPD.stSongPos st of
    -- Just n -> modifyCurrentSongList (\l -> ListWidget.setPosition l n)
    _      -> return ()

  -- source ~/.vimusrc
  -- FIXME:
  --  * proper error detection/handling
  vimusrc <- liftIO readVimusRc
  forM_ vimusrc $ \line ->
    case line of
      []        -> return ()
      '#':_     -> return ()
      s         -> runCommand s

  setCurrentView Playlist
  renderMainWindow

  forever $ do
    c <- getChar
    case c of
      -- a command
      ':' ->  do
                input <- Input.readline_ window ':' getChar
                maybe (return ()) runCommand input
                renderMainWindow

      {-
      -- search
      '/' ->  do
                input <- Input.readline searchPreview window '/' getChar
                maybe (return ()) search input
                renderMainWindow

      -- filter-search
      'F' ->  withCurrentSongList $ \widget -> do
                cache <- liftIO $ newIORef [("", ListWidget.setPosition widget 0)]
                input <- Input.readline (filterPreview cache) window '/' getChar
                case input of
                  Just t  -> do
                    modify $ \state -> state { searchResult = ListWidget.filter (filterPredicate t widget) widget }
                    setCurrentView SearchResult
                  Nothing -> return ()
                modifyCurrentSongList (\l -> ListWidget.setPosition l 0)
                renderMainWindow
      -}

      -- macro expansion
      _   ->  do
                macros <- gets programStateMacros
                expandMacro macros getChar Input.ungetstr [c]
  where
    {-
    searchPreview term =
      withCurrentList $ \widget ->
        renderToMainWindow $ ListWidget.search (searchPredicate term widget) widget
    -}

    {-
    filterPreview cache term = do
      liftIO $ modifyIORef cache updateCache
      -- cache now contains results for all `inits term', in reverse order
      -- TODO: write some quickcheck properties
      r <- liftIO $ readIORef cache
      renderToMainWindow $ snd $ head r
      where
        updateCache []               = error "this should never happen"
        updateCache list@((t, l):xs) =
          if term == t then
            list
          else if isPrefixOf t term then
            (term, ListWidget.filter (filterPredicate term l) l) : list
          else
            updateCache xs
    -}

    getChar = do
      handleNotifies chan
      c <- Input.wgetch window
      if c == '\0'
        then getChar
        else if (c == keyResize) then do
          state <- get
          liftIO $ delwin $ mainWindow state
          win <- liftIO onResize
          size <- liftIO $ getmaxyx win
          put state { mainWindow = win }

          withAllWidgets $ sendEvent (EvResize size)

          renderMainWindow
          getChar
        else return c


data Notify = NotifyPlaylistChanged
            | NotifyLibraryChanged
            | NotifyAction (Vimus ())


handleNotifies :: Chan Notify -> Vimus ()
handleNotifies chan = whileM_ (liftIO $ fmap not $ isEmptyChan chan) $ do
  notify <- liftIO $ readChan chan
  case notify of
    NotifyPlaylistChanged -> (withAllWidgets $ sendEvent EvPlaylistChanged) >> renderMainWindow
    NotifyLibraryChanged  -> (withAllWidgets $ sendEvent EvLibraryChanged)  >> renderMainWindow
    NotifyAction action   -> action


------------------------------------------------------------------------
-- mpd status

updateStatus :: (MonadIO m) => Window -> Window -> PlaybackState -> m ()
updateStatus songWindow playWindow st = do

  putString songWindow song
  putString playWindow playState
  where
    song = fromMaybe "none" $ fmap Song.title $ PlaybackState.currentSong st

    playState = stateSymbol ++ " " ++ formatTime current ++ " / " ++ formatTime total ++ " " ++ tags
      where
        (current, total) = PlaybackState.elapsedTime st
        stateSymbol = case PlaybackState.playState st of
          MPD.Playing -> "|>"
          MPD.Paused  -> "||"
          MPD.Stopped -> "[]"

        tags = case filter (($ PlaybackState.playStatus st) . fst) tagList of
          []   -> ""
          x:xs -> "[" ++ snd x ++ concatMap ((", "++) . snd) xs ++ "]"

        tagList = [
            (MPD.stRepeat ,  "repeat")
          , (MPD.stRandom ,  "random")
          , (MPD.stSingle ,  "single")
          , (MPD.stConsume, "consume")
          ]

    formatTime :: Seconds -> String
    formatTime s = printf "%02d:%02d" minutes seconds
      where
        minutes = s `div` 60
        seconds = s `mod` 60

    putString :: (MonadIO m) => Window -> String -> m ()
    putString window string = liftIO $ do
      mvwaddstr window 0 0 string
      wclrtoeol window
      wrefresh window
      return ()


------------------------------------------------------------------------
-- Tabs



------------------------------------------------------------------------
-- Program entry point

run :: Maybe String -> Maybe String -> IO ()
run host port = do

  (onResize, tw, mw, statusWindow, songStatusWindow, playStatusWindow, inputWindow) <- WindowLayout.create

  -- thread for playback state
  notifyChan <- newChan
  forkIO $ withMPD $ PlaybackState.onChange $ \st -> do
    writeChan notifyChan $ NotifyAction $ updateStatus songStatusWindow playStatusWindow st

  -- thread for asynchronous updates
  liftIO $ writeChan notifyChan NotifyLibraryChanged
  forkIO $ withMPD $ forever $ do
    l <- MPD.idle
    when (MPD.PlaylistS `elem` l) $ do
      liftIO $ writeChan notifyChan NotifyPlaylistChanged
    when (MPD.DatabaseS `elem` l) $ do
      liftIO $ writeChan notifyChan NotifyLibraryChanged


  -- We use a timeout of 10 ms, but be aware that the actual timeout may be
  -- different due to a combination of two facts:
  --
  -- (1) ncurses getch (and related functions) returns when a signal occurs
  -- (2) the threaded GHC runtime uses signals for bookkeeping
  --     (see +RTS -V option)
  --
  -- So the effective timeout is swayed by the runtime.
  --
  -- We may workaround this in the future, as suggest here:
  -- http://www.serpentine.com/blog/2010/09/04/dealing-with-fragile-c-libraries-e-g-mysql-from-haskell/
  wtimeout inputWindow 10

  keypad inputWindow True

  mvwaddstr inputWindow 0 0 "type 'q' to exit, read 'src/Macro.hs' for help"
  wrefresh inputWindow

  let create = createListWidget mw ([] :: [Content])
  [pl, lw, bw, sr] <- sequence [create, create, create, create]
  hs <- createListWidget mw $ sort globalCommands

  withMPD $ runStateT (mainLoop inputWindow notifyChan onResize) ProgramState {
      tabView           = tabFromList [
          (Playlist    , makeContentListWidget handlePlaylist pl)
        , (Library     , makeContentListWidget handleLibrary  lw)
        , (Browser     , makeContentListWidget handleBrowser  bw)
        , (SearchResult, makeContentListWidget noHandler      sr)
        , (Help        , makeListWidget        noHandler      hs)
        ]
    , mainWindow      = mw
    , statusLine      = statusWindow
    , tabWindow         = tw
    , getLastSearchTerm = ""
    , programStateMacros = defaultMacros
    , libraryPath        = Nothing
    }
  return ()

  where
    withMPD :: (MonadIO m) => MPD.MPD a -> m a
    withMPD action = do
      result <- liftIO $ withMPD_ host port action
      case result of
          Left  e -> fail $ show e
          Right r -> return r

    noHandler :: Handler a
    noHandler _ _ = return Nothing


main :: IO ()
main = do

  (host, port) <- getOptions

  -- recommended in ncurses manpage
  initscr
  raw
  noecho

  -- suggested  in ncurses manpage
  -- nonl
  intrflush stdscr True

  -- enable colors
  start_color

  curs_set 0

  finally (run host port) endwin
