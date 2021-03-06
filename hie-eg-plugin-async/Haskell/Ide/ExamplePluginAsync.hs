{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
module Haskell.Ide.ExamplePluginAsync where

import           Control.Concurrent
import           Control.Concurrent.STM.TChan
import           Control.Monad.IO.Class
import           Control.Monad.STM
import           Haskell.Ide.Engine.ExtensibleState
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.PluginUtils
import           Data.Monoid
import qualified Data.Map as Map
import qualified Data.Text as T

-- ---------------------------------------------------------------------

exampleAsyncDescriptor :: PluginDescriptor
exampleAsyncDescriptor = PluginDescriptor
  {
    pdUIShortName = "Async Example"
  , pdUIOverview = "An example HIE plugin using multiple/async processes"
  , pdCommands =
      [
        buildCommand (longRunningCmdSync Cmd1) "cmd1" "Long running synchronous command" [] [CtxNone] []
      , buildCommand (longRunningCmdSync Cmd2) "cmd2" "Long running synchronous command" [] [CtxNone] []
      ]
  , pdExposedServices = []
  , pdUsedServices    = []
  }

-- ---------------------------------------------------------------------

data WorkerCmd = Cmd1 | Cmd2
               deriving Show

-- | Keep track of the communication channesl to the remote process.
data SubProcess = SubProcess
  { spChIn    :: TChan WorkerCmd
  , spChOut   :: TChan T.Text
  , spProcess :: ThreadId
  }

-- | Wrap it in a Maybe for pure initialisation
data AsyncPluginState = APS (Maybe SubProcess)

-- | Tag the state variable to enable it to be stored in the dispatcher state,
-- accessible to all plugins, provided they know the type, as it is accessed via
-- a @cast@
instance ExtensionClass AsyncPluginState where
  initialValue = APS Nothing

-- ---------------------------------------------------------------------

-- | This command manages interaction with a separate process, doing stuff.
longRunningCmdSync :: WorkerCmd -> CommandFunc T.Text
longRunningCmdSync cmd = CmdSync $ \_ctx req -> do
  SubProcess cin cout _tid <- ensureProcessRunning
  liftIO $ atomically $ writeTChan cin cmd
  res <- liftIO $ atomically $ readTChan cout
  return (IdeResponseOk $ "res=" <> res)

-- ---------------------------------------------------------------------

-- | If there is already a @SubProcess@ value in the plugin state return it,
-- else create a new set of @TChan@ and fork the worker with them, storing the
-- new @SubProcess@ value in the plugin state.
ensureProcessRunning :: IdeM SubProcess
ensureProcessRunning = do
  (APS v) <- get -- from extensible state
  sp <- case v of
    Nothing -> do
      cin  <- liftIO $ atomically newTChan
      cout <- liftIO $ atomically newTChan
      tid  <- liftIO $ forkIO (workerProc cin cout)
      let v' = SubProcess cin cout tid
      put (APS (Just v')) -- into extensible state
      return v'
    Just v' -> return v'
  return sp

-- ---------------------------------------------------------------------

-- | Long running worker process, can be doing commands in an async manner
workerProc :: TChan WorkerCmd -> TChan T.Text -> IO ()
workerProc cin cout = loop 1
  where
    loop cnt = do
      debugm "workerProc:top of loop"
      req <- liftIO $ atomically $ readTChan cin
      debugm $ "workerProc loop:got:" ++ show req
      case req of
        Cmd1 -> do
          liftIO $ atomically $ writeTChan cout (T.pack $ "wp cmd1:cnt=" ++ show cnt)
          loop (cnt + 1)
        Cmd2 -> do
          liftIO $ atomically $ writeTChan cout (T.pack $ "wp cmd2:cnt=" ++ show cnt)
          loop (cnt + 1)

-- ---------------------------------------------------------------------
