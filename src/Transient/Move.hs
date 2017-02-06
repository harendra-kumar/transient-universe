-----------------------------------------------------------------------------
--
-- Module      :  Transient.Move
-- Copyright   :
-- License     :  GPL-3
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
--
-- | see <https://www.fpcomplete.com/user/agocorona/moving-haskell-processes-between-nodes-transient-effects-iv>
-----------------------------------------------------------------------------
{-# LANGUAGE DeriveDataTypeable , ExistentialQuantification, OverloadedStrings
    ,ScopedTypeVariables, StandaloneDeriving, RecordWildCards, FlexibleContexts, CPP
    ,GeneralizedNewtypeDeriving #-}
module Transient.Move(

-- * running the Cloud monad
Cloud(..),runCloud, runCloudIO, runCloudIO', local, onAll, lazy, loggedc, lliftIO,localIO,
listen, Transient.Move.connect, connect', fullStop,

-- * primitives for communication
wormhole, teleport, copyData,



-- * single node invocation
beamTo, forkTo, streamFrom, callTo, runAt, atRemote,

-- * invocation of many nodes
clustered, mclustered, callNodes,

-- * messaging
putMailbox, putMailbox',getMailbox,getMailbox',cleanMailbox,cleanMailbox',

-- * thread control
single, unique,

#ifndef ghcjs_HOST_OS
-- * buffering contril
setBuffSize, getBuffSize,
#endif

-- * API
api,

-- * node management
createNode, createWebNode, createNodeServ, getMyNode, getNodes,
addNodes, shuffleNodes,

-- * low level

 getWebServerNode, Node(..), nodeList, Connection(..), Service(),
 isBrowserInstance,

 defConnection,
 ConnectionData(..),
#ifndef ghcjs_HOST_OS
 ParseContext(..)
#endif

) where

import Transient.Internals
import Transient.Logged
import Transient.Indeterminism(choose)
import Transient.Backtrack
import Transient.EVars
import Data.Typeable
import Control.Applicative
#ifndef ghcjs_HOST_OS
import Network
import Network.Info
--import qualified Data.IP as IP
import qualified Network.Socket as NS
import qualified Network.BSD as BSD
import qualified Network.WebSockets as NWS(RequestHead(..))

import qualified Network.WebSockets.Connection   as WS

import Network.WebSockets.Stream   hiding(parse)
import qualified Data.ByteString       as B             (ByteString,concat)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Internal as BLC
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BS
import Network.Socket.ByteString as SBS(send,sendMany,sendAll,recv)
import qualified Network.Socket.ByteString.Lazy as SBSL
import Data.CaseInsensitive(mk)
import Data.Char(isSpace)
--import GHCJS.Perch (JSString)
#else
import  JavaScript.Web.WebSocket
import  qualified JavaScript.Web.MessageEvent as JM
import GHCJS.Prim (JSVal)
import GHCJS.Marshal(fromJSValUnchecked)
import qualified Data.JSString as JS


import           JavaScript.Web.MessageEvent.Internal
import           GHCJS.Foreign.Callback.Internal (Callback(..))
import qualified GHCJS.Foreign.Callback          as CB
import Data.JSString  (JSString(..), pack)

#endif


import Control.Monad.State
import System.IO
import Control.Exception hiding (onException)
import Data.Maybe
--import Data.Hashable

--import System.Directory
import Control.Monad

import System.IO.Unsafe
import Control.Concurrent.STM as STM
import Control.Concurrent.MVar

import Data.Monoid
import qualified Data.Map as M
import Data.List (nub,(\\),find, insert)
import Data.IORef



import System.IO

import Control.Concurrent





import Data.Dynamic
import Data.String

import System.Mem.StableName
import Unsafe.Coerce

--import System.Random

#ifdef ghcjs_HOST_OS
type HostName  = String
newtype PortID = PortNumber Int deriving (Read, Show, Eq, Typeable)
#endif

data Node= Node{ nodeHost   :: HostName
               , nodePort   :: Int
               , connection :: MVar Pool
               , nodeServices   :: [Service]
               }

         deriving (Typeable)

instance Ord Node where
   compare node1 node2= compare (nodeHost node1,nodePort node1)(nodeHost node2,nodePort node2)


-- The cloud monad is a thin layer over Transient in order to make sure that the type system
-- forces the logging of intermediate results
newtype Cloud a= Cloud {runCloud' ::TransIO a} deriving (Functor,Applicative,Monoid,Alternative, Monad, Num, MonadState EventF)


runCloud x= do
       closRemote  <- getSData <|> return (Closure 0)
       runCloud' x <*** setData  closRemote

--
--
--instance Applicative Cloud  where
--
--   pure = return
--
--   x <*> y= Cloud . Transient $ do
--       l1 <- liftIO $ newIORef Nothing
--       l2 <- liftIO $ newIORef Nothing
--       runTrans $ do
--           Log _  _ full <- getData `onNothing` error "instance Applicative: no log"
--           r <- runCloud (eval l1 x) <*> runCloud (eval l2 y)
--           Just v1 <- localIO $ readIORef l1
--           Just v2 <- localIO $ readIORef l2
--           let full' = Var (toIDyn v1) : Var (toIDyn v2) : full
--           setData $ Log False full' full'
--           return r
--       where
--       eval l x= x >>= \v -> localIO (writeIORef l $ Just v) >> return v
--


--instance Monoid a => Monoid (Cloud a) where
--   mappend x y = mappend <$> x <*> y
--   mempty= return mempty

-- | Means that this computation will be executed in the current node. the result will be logged
-- so the closure will be recovered if the computation is translated to other node by means of
-- primitives like `beamTo`, `forkTo`, `runAt`, `teleport`, `clustered`, `mclustered` etc
local :: Loggable a => TransIO a -> Cloud a
local =  Cloud . logged

--stream :: Loggable a => TransIO a -> Cloud (StreamVar a)
--stream= Cloud . transport

-- #ifndef ghcjs_HOST_OS
-- | run the cloud computation.
runCloudIO :: Typeable a =>  Cloud a -> IO (Maybe a)
runCloudIO (Cloud mx)= keep mx

-- | run the cloud computation with no console input
runCloudIO' :: Typeable a =>  Cloud a -> IO (Maybe a)
runCloudIO' (Cloud mx)=  keep' mx

-- #endif

-- | alternative to `local` It means that if the computation is translated to other node
-- this will be executed again if this has not been executed inside a `local` computation.
--
-- > onAll foo
-- > local foo'
-- > local $ do
-- >       bar
-- >       runCloud $ do
-- >               onAll baz
-- >               runAt node ....
-- > callTo node' .....
--
-- Here foo will be executed in node' but foo' bar and baz don't.
--
-- However foo bar and baz will e executed in node.
--

onAll ::  TransIO a -> Cloud a
onAll =  Cloud

lazy :: TransIO a -> Cloud a
lazy mx= onAll $ getCont >>= \st -> Transient $
        return $ unsafePerformIO $  runStateT (runTrans mx) st >>=  return .fst

-- log the result a cloud computation. like `loogged`, This eliminated all the log produced by computations
-- inside and substitute it for that single result when the computation is completed.
loggedc :: Loggable a => Cloud a -> Cloud a
loggedc (Cloud mx)= Cloud $ do
    closRemote  <- getSData <|> return (Closure 0 )
    logged mx <*** setData  closRemote


loggedc' :: Loggable a => Cloud a -> Cloud a
loggedc' (Cloud mx)= Cloud $ logged mx

-- | the `Cloud` monad has no `MonadIO` instance. `lliftIO= local . liftIO`
lliftIO :: Loggable a => IO a -> Cloud a
lliftIO= local . liftIO

-- | locally perform IO. `localIO = lliftIO`
localIO :: Loggable a => IO a -> Cloud a
localIO= lliftIO

--remote :: Loggable a => TransIO a -> Cloud a
--remote x= Cloud $ step' x $ \full x ->  Transient $ do
--            let add= Wormhole: full
--            setData $ Log False add add
--
--            r <-  runTrans x
--
--            let add= WaitRemote: full
--            (setData $ Log False add add)     -- !!> "AFTER STEP"
--            return  r

-- | stop the current computation and does not execute any alternative computation
fullStop :: Cloud stop
fullStop= onAll $ setData WasRemote >> stop


-- | continue the execution in a new node
-- all the previous actions from `listen` to this statement must have been logged
beamTo :: Node -> Cloud ()
beamTo node =  wormhole node teleport


-- | execute in the remote node a process with the same execution state
forkTo  :: Node -> Cloud ()
forkTo node= beamTo node <|> return()

-- | open a wormhole to another node and executes an action on it.
-- currently by default it keep open the connection to receive additional requests
-- and responses (streaming)
callTo :: Loggable a => Node -> Cloud a -> Cloud a
callTo node  remoteProc=
   wormhole node $ atRemote remoteProc

-- |  Within an open connection to other node opened by `wormhole`, it run the computation in the remote node and return
-- the result back  to the original node.
atRemote proc= loggedc' $ do
     teleport                    -- !> "teleport 1111"
     r <- Cloud $ runCloud proc <** setData WasRemote
     teleport                    -- !> "teleport 2222"
     return r

-- | synonymous of `callTo`
runAt :: Loggable a => Node -> Cloud a -> Cloud a
runAt= callTo

-- | run a single thread with that action for each connection created.
-- When the same action is re-executed within that connection, all the threads generated by the previous execution
-- are killed
--
-- >   box <-  foo
-- >   r <- runAt node . local . single $ getMailbox box
-- >   localIO $ print r
--
-- if foo  return differnt mainbox indentifiers, the above code would print the
-- messages of  the last one.
-- Without single, it would print the messages of all of them.
single :: TransIO a -> TransIO a
single f= do
   con@Connection{closChildren=rmap} <- getSData <|> error "single: only works within a wormhole"
   mapth <- liftIO $ readIORef rmap
   id <- liftIO $ makeStableName f >>= return .  hashStableName

--   chs <-
--   let mx =
   case  M.lookup id mapth of
          Just tv ->  liftIO $ killChildren tv    -- !> "JUSTTTTTTTTT"
          Nothing ->  return () --gets children

--   liftIO $  killChildren   chs

--   modify $ \ s -> s{children= chs}  -- to allow his own thread control

   f <** do
      id <- liftIO $ makeStableName f >>= return . hashStableName
      chs <- gets children
      liftIO $ modifyIORef rmap $ \mapth -> M.insert id chs mapth
--      return r

-- | run an unique continuation for each connection. The first thread that execute `unique` is
-- executed for that connection. The rest are ignored.
unique :: a -> TransIO ()
unique f= do
   con@Connection{closChildren=rmap} <- getSData <|> error "unique: only works within a connection. Use wormhole"
   mapth <- liftIO $ readIORef rmap
   id <- liftIO $ f `seq` makeStableName f >>= return .  hashStableName

   let mx = M.lookup id mapth
   case mx of
          Just tv -> empty
          Nothing -> do
             chs <- gets children
             liftIO $ modifyIORef rmap $ \mapth -> M.insert id chs mapth




msend :: Loggable a => Connection -> StreamData a -> TransIO ()

#ifndef ghcjs_HOST_OS

msend (Connection _(Just (Node2Node _ sock _)) _ _ blocked _ _ _) r= do
   liftIO $   withMVar blocked $  const $ SBS.sendAll sock $ BC.pack (show r)




msend (Connection _(Just (Node2Web sconn)) _ _ blocked _  _ _) r=liftIO $
  {-withMVar blocked $ const $ -} WS.sendTextData sconn $ BS.pack (show r)


#else

msend (Connection _ (Just (Web2Node sconn)) _ _ blocked _  _ _) r= liftIO $
  withMVar blocked $ const $ JavaScript.Web.WebSocket.send  (JS.pack $ show r) sconn   -- !!> "MSEND SOCKET"



#endif

msend (Connection _ Nothing _ _  _ _ _ _) _= error "msend out of wormhole context"

mread :: Loggable a => Connection -> TransIO (StreamData a)


#ifdef ghcjs_HOST_OS


mread (Connection _ (Just (Web2Node sconn)) _ _ _ _  _ _)=  wsRead sconn



wsRead :: Loggable a => WebSocket  -> TransIO  a
wsRead ws= do
  dat <- react (hsonmessage ws) (return ())
  case JM.getData dat of
    JM.StringData str  ->  return (read' $ JS.unpack str)
--                  !> ("Browser webSocket read", str)  !> "<------<----<----<------"
    JM.BlobData   blob -> error " blob"
    JM.ArrayBufferData arrBuffer -> error "arrBuffer"



wsOpen :: JS.JSString -> TransIO WebSocket
wsOpen url= do
   ws <-  liftIO $ js_createDefault url      --  !> ("wsopen",url)
   react (hsopen ws) (return ())             -- !!> "react"
   return ws                                 -- !!> "AFTER ReACT"

foreign import javascript safe
    "window.location.hostname"
   js_hostname ::    JSVal

foreign import javascript safe
   "(function(){var res=window.location.href.split(':')[2];if (res === undefined){return 80} else return res.split('/')[0];})()"
   js_port ::   JSVal

foreign import javascript safe
    "$1.onmessage =$2;"
   js_onmessage :: WebSocket  -> JSVal  -> IO ()


getWebServerNode :: TransIO Node
getWebServerNode = liftIO $ do

   h <- fromJSValUnchecked js_hostname
   p <- fromIntegral <$> (fromJSValUnchecked js_port :: IO Int)
   createNode h p


hsonmessage ::WebSocket -> (MessageEvent ->IO()) -> IO ()
hsonmessage ws hscb= do
  cb <- makeCallback MessageEvent hscb
  js_onmessage ws cb

foreign import javascript safe
             "$1.onopen =$2;"
   js_open :: WebSocket  -> JSVal  -> IO ()

newtype OpenEvent = OpenEvent JSVal deriving Typeable
hsopen ::  WebSocket -> (OpenEvent ->IO()) -> IO ()
hsopen ws hscb= do
   cb <- makeCallback OpenEvent hscb
   js_open ws cb

makeCallback :: (JSVal -> a) ->  (a -> IO ()) -> IO JSVal

makeCallback f g = do
   Callback cb <- CB.syncCallback1 CB.ContinueAsync (g . f)
   return cb


foreign import javascript safe
   "new WebSocket($1)" js_createDefault :: JS.JSString -> IO WebSocket


#else
mread (Connection _(Just (Node2Node _ _ _)) _ _ blocked _ _ _) =  parallelReadHandler -- !> "mread"


mread (Connection node  (Just (Node2Web sconn )) bufSize events blocked _ _ _)=
        parallel $ do
            s <- WS.receiveData sconn
            return . read' $  BS.unpack s
--                 !>  ("WS MREAD RECEIVED ---->", s)



getWebServerNode :: TransIO Node
getWebServerNode = getMyNode
#endif

read' s= case readsPrec' 0 s of
       [(x,"")] -> x
       _  -> error $ "reading " ++ s

-- | A wormhole opens a connection with another node anywhere in a computation.
-- `teleport` uses this connection to translate the computation back and forth between the two nodes connected
wormhole :: Loggable a => Node -> Cloud a -> Cloud a
wormhole node (Cloud comp) = local $ Transient $ do

   moldconn <- getData :: StateIO (Maybe Connection)
   mclosure <- getData :: StateIO (Maybe Closure)
   labelState $ "wormhole" ++ show node
   logdata@(Log rec log fulLog) <- getData `onNothing` return (Log False [][])

   mynode <- runTrans getMyNode     -- debug
   if not rec                                    --  !> ("wormhole recovery", rec)
            then runTrans $ (do

                    conn <-  mconnect node
                                                 -- !> ("wormhole",mynode,"connecting node ",  node)
                    setData  conn{calling= True}
-- #ifdef ghcjs_HOST_OS
--                    addPrefix    -- for the DOM identifiers
-- #endif
                    comp )
                  <*** do when (isJust moldconn) . setData $ fromJust moldconn
                          when (isJust mclosure) . setData $ fromJust mclosure

                    -- <** is not enough
            else do
             let conn = fromMaybe (error "wormhole: no connection in remote node") moldconn
--             conn <- getData `onNothing` error "wormhole: no connection in remote node"

             setData $ conn{calling= False}

             runTrans $  comp
                     <*** do
--                          when (null log) $ setData WasRemote    !> "NULLLOG"
                          when (isJust mclosure) . setData $ fromJust mclosure




#ifndef ghcjs_HOST_OS
type JSString= String
pack= id



#endif
--
--newtype Prefix= Prefix JSString deriving(Read,Show)
--{-#NOINLINE rprefix #-}
--rprefix= unsafePerformIO $ newIORef 0
--addPrefix :: (MonadIO m, MonadState EventF m) => m ()
--addPrefix=  do
--   r <- liftIO $ atomicModifyIORef rprefix (\n -> (n+1,n))  -- liftIO $ replicateM  5 (randomRIO ('a','z'))
--   (setData $ Prefix $ pack $ show r) !> "addPrefix"
--



-- | translates computations back and forth between two nodes
-- reusing a connection opened by `wormhole`
--
-- each teleport transport to the other node what is new in the log since the
-- last teleport
--
-- It is used trough other primitives like  `runAt` which involves two teleports:
--
-- runAt node= wormhole node $ loggedc $ do
-- >     teleport
-- >     r <- Cloud $ runCloud proc <** setData WasRemote
-- >     teleport
-- >     return r

teleport ::   Cloud ()
teleport =  do
  local $ Transient $ do

     cont <- get

     -- send log with closure at head
     Log rec log fulLog <- getData `onNothing` return (Log False [][])
     if not rec   -- !> ("teleport rec,loc fulLog=",rec,log,fulLog)
                  -- if is not recovering in the remote node then it is active
      then  do
         conn@Connection{closures= closures,calling= calling} <- getData
             `onNothing` error "teleport: No connection defined: use wormhole"

         --read this Closure
         Closure closRemote  <- getData `onNothing` return (Closure 0 )

         --set his own closure in his Node data

         let closLocal = sum $ map (\x-> case x of Wait -> 100000;
                                                   Exec -> 1000
                                                   _ -> 1) fulLog

--         closLocal  <-   liftIO $ randomRIO (0,1000000)
         node <- runTrans getMyNode

         liftIO $ modifyMVar_ closures $ \map -> return $ M.insert closLocal (fulLog,cont) map

         let tosend= reverse $ if closRemote==0 then fulLog else  log -- drop offset  $ reverse fulLog


         runTrans $ msend conn $ SMore (closRemote,closLocal, tosend )
--                                                  !> ("teleport sending", tosend )
--                                                  !> "--------->------>---------->"
--                                                  !> ("fulLog", fulLog)

         setData $ if (not calling) then  WasRemote else WasParallel

         return Nothing

      else do

         delData WasRemote                -- !> "deleting wasremote in teleport"
                                          -- it is recovering, therefore it will be the
                                          -- local, not remote

         return (Just ())                           --  !> "TELEPORT remote"




-- | copy a session data variable from the local to the remote node.
-- If there is none set in the local node, The parameter is the default value.
-- In this case, the default value is also set in the local node.
copyData def = do
  r <- local getSData <|> return def
  onAll $ setData r
  return r

-- | `callTo` can stream data but can not inform the receiving process about the finalization. This call
-- does it.
streamFrom :: Loggable a => Node -> Cloud (StreamData a) -> Cloud  (StreamData a)
streamFrom = callTo


--release (Node h p rpool _) hand= liftIO $ do
----    print "RELEASED"
--    atomicModifyIORef rpool $  \ hs -> (hand:hs,())
--      -- !!> "RELEASED"

mclose :: Connection -> IO ()

#ifndef ghcjs_HOST_OS

mclose (Connection _
   (Just (Node2Node _  sock _ )) _ _ _ _ _ _)= NS.sClose sock

mclose (Connection node
   (Just (Node2Web sconn ))
   bufSize events blocked _  _ _)=
    WS.sendClose sconn ("closemsg" :: BS.ByteString)

#else

mclose (Connection _ (Just (Web2Node sconn)) _ _ blocked _ _ _)=
    JavaScript.Web.WebSocket.close Nothing Nothing sconn

#endif



mconnect :: Node -> TransIO  Connection
mconnect  node@(Node _ _ _ _ )=  do
  nodes <- getNodes
--                                                          !> ("connecting node", node)

  let fnode =  filter (==node) nodes
  case fnode of
   [] -> addNodes [node] >> mconnect node
   [Node host port  pool _] -> do


    plist <- liftIO $ readMVar pool
    case plist  of
      handle:_ -> do
                  delData $ Closure undefined
                  return  handle
--                                                            !>   ("REUSED!", node)

      _ -> do
--        liftIO $ putStr "*****CONNECTING NODE: " >> print node
        my <- getMyNode
--        liftIO  $ putStr "OPENING CONNECTION WITH :" >> print port
        Connection{comEvent= ev} <- getSData <|> error "connect: listen not set for this node"

#ifndef ghcjs_HOST_OS

        conn <- liftIO $ do
            let size=8192
            sock <-  connectTo'  size  host $ PortNumber $ fromIntegral port
--                                                                                 !> ("CONNECTING ",port)
            conn <- defConnection >>= \c -> return c{myNode=my,comEvent= ev,connData= Just $ Node2Node u  sock (error $ "addr: outgoing connection")}
            SBS.sendAll sock "CLOS a b\n\n"
--                                                                                   !> "sending CLOS"
            return conn

#else
        conn <- do
            ws <- connectToWS host $ PortNumber $ fromIntegral port
--                                                                                      !> "CONNECTWS"
            conn <- defConnection >>= \c -> return c{comEvent= ev,connData= Just $ Web2Node ws}
            return conn    -- !>  ("websocker CONNECION")
#endif
        chs <- liftIO $ newIORef M.empty
        let conn'= conn{closChildren= chs}
        liftIO $ modifyMVar_ pool $  \plist -> return $ conn':plist
        putMailbox  (conn',node)  -- tell listenResponses to watch incoming responses
        delData $ Closure undefined
        return  conn

  where u= undefined



-- mconnect _ = empty



#ifndef ghcjs_HOST_OS
connectTo' bufSize hostname (PortNumber port) =  do
        proto <- BSD.getProtocolNumber "tcp"
        bracketOnError
            (NS.socket NS.AF_INET NS.Stream proto)
            (sClose)  -- only done if there's an error
            (\sock -> do
              NS.setSocketOption sock NS.RecvBuffer bufSize
              NS.setSocketOption sock NS.SendBuffer bufSize
--              NS.setSocketOption sock NS.SendTimeOut 1000000  !> ("CONNECT",port)

              he <- BSD.getHostByName hostname

              NS.connect sock (NS.SockAddrInet port (BSD.hostAddress he))

              return sock)

#else
connectToWS  h (PortNumber p) =
   wsOpen $ JS.pack $ "ws://"++ h++ ":"++ show p
#endif

#ifndef ghcjs_HOST_OS
-- | A connectionless version of callTo for long running remote calls
callTo' :: (Show a, Read a,Typeable a) => Node -> Cloud a -> Cloud a
callTo' node remoteProc=  do
    mynode <-  local getMyNode
    beamTo node
    r <-  remoteProc
    beamTo mynode
    return r
#endif

type Blocked= MVar ()
type BuffSize = Int
data ConnectionData=
#ifndef ghcjs_HOST_OS
                   Node2Node{port :: PortID
                            ,socket ::Socket
                            ,remoteNode :: NS.SockAddr
                             }

                   | Node2Web{webSocket :: WS.Connection}
#else

                   Web2Node{webSocket :: WebSocket}
#endif

data MailboxId= MailboxId Int TypeRep deriving (Eq,Ord)

data Connection= Connection{myNode     :: Node
                           ,connData   :: Maybe(ConnectionData)
                           ,bufferSize :: BuffSize
                           -- Used by getMailBox, putMailBox
                           ,comEvent   :: IORef (M.Map MailboxId (EVar SData))
                           -- multiple wormhole/teleport use the same connection concurrently
                           ,blocked    :: Blocked
                           ,calling    :: Bool
                           -- local closures with his log and his continuation
                           ,closures   :: MVar (M.Map IdClosure ([LogElem], EventF))

                           -- for each remote closure that points to local closure 0,
                           -- a new container of child processes
                           -- in order to treat them separately
                           -- so that 'killChilds' do not kill unrelated processes
                           ,closChildren :: IORef (M.Map Int (MVar[EventF]))}

                  deriving Typeable




-- | write to the mailbox
-- Mailboxes are node-wide, for all processes that share the same connection data, that is, are under the
-- same `listen`  or `connect`
-- while EVars are only visible by the process that initialized  it and his children.
-- Internally, the mailbox is in a well known EVar stored by `listen` in the `Connection` state.
putMailbox :: Typeable a => a -> TransIO ()
putMailbox = putMailbox' 0

-- | write to a mailbox identified by an Integer besides the type
putMailbox' :: Typeable a =>  Int -> a -> TransIO ()
putMailbox'  idbox dat= do
   let name= MailboxId idbox $ typeOf dat
   Connection{comEvent= mv} <- getData `onNothing` errorMailBox
   mbs <- liftIO $ readIORef mv
   let mev =  M.lookup name mbs
   case mev of
     Nothing ->newMailbox name >> putMailbox' idbox dat
     Just ev -> writeEVar ev $ unsafeCoerce dat


newMailbox :: MailboxId -> TransIO ()
newMailbox name= do
--   return ()  -- !> "newMailBox"
   Connection{comEvent= mv} <- getData `onNothing` errorMailBox
   ev <- newEVar
   liftIO $ atomicModifyIORef mv $ \mailboxes ->   (M.insert name ev mailboxes,())


errorMailBox= error "MailBox: No connection open. Use wormhole"

-- | get messages from the mailbox that matches with the type expected.
-- The order of reading is defined by `readTChan`
-- This is reactive. it means that each new message trigger the execution of the continuation
-- each message wake up all the `getMailbox` computations waiting for it.
getMailbox :: Typeable a => TransIO a
getMailbox = getMailbox' 0

-- | read from a mailbox identified by a number besides the type
getMailbox' :: Typeable a => Int -> TransIO a
getMailbox' mboxid = x where
 x = do

   let name= MailboxId mboxid $ typeOf $ typeOf1 x
   Connection{comEvent= mv} <- getData `onNothing` errorMailBox
   mbs <- liftIO $ readIORef mv
   let mev =  M.lookup name mbs
   case mev of
     Nothing ->newMailbox name >> getMailbox' mboxid
     Just ev ->unsafeCoerce $ readEVar ev

 typeOf1 :: TransIO a -> a
 typeOf1 = undefined

-- | delete all subscriptions for that mailbox expecting this kind of data
cleanMailbox :: Typeable a => a -> TransIO ()
cleanMailbox = cleanMailbox' 0

-- | clean a mailbox identified by an Int and the type
cleanMailbox' :: Typeable a => Int ->  a -> TransIO ()
cleanMailbox'  mboxid witness= do
   let name= MailboxId mboxid $ typeOf witness
   Connection{comEvent= mv} <- getData `onNothing` error "getMailBox: accessing network events out of listen"
   mbs <- liftIO $ readIORef mv
   let mev =  M.lookup name mbs
   case mev of
     Nothing -> return()
     Just ev -> do cleanEVar ev
                   liftIO $ atomicModifyIORef mv $ \mbs -> (M.delete name mbs,())





defConnection :: MonadIO m => m Connection

-- #ifndef ghcjs_HOST_OS
defConnection = liftIO $ do
  x <- newMVar ()
  y <- newMVar M.empty
  z <-  return $ error "closchildren newIORef M.empty"
  return $ Connection (error "node in default connection") Nothing  8192
                 (error "defConnection: accessing network events out of listen")
                 x  False y z



#ifndef ghcjs_HOST_OS
setBuffSize :: Int -> TransIO ()
setBuffSize size= Transient $ do
   conn<- getData `onNothing`  defConnection
   setData $ conn{bufferSize= size}
   return $ Just ()

getBuffSize=
  (do getSData >>= return . bufferSize) <|> return  8192




listen ::  Node ->  Cloud ()
listen  (node@(Node _   port _ _ )) = onAll $ do
   addThreads 1

   setData $ Log False [] []

   conn' <- getSData <|> defConnection
   ev <- liftIO $ newIORef M.empty
   chs <- liftIO $ newIORef M.empty
   let conn= conn'{myNode=node, comEvent=ev,closChildren=chs}

   setData conn
   addNodes [node]
   mlog <- listenNew (fromIntegral port) conn  <|> listenResponses

   execLog  mlog

-- listen incoming requests
listenNew port conn'= do
   labelState "listen"
   sock <- liftIO . listenOn  $ PortNumber port

   let bufSize= bufferSize conn'
   liftIO $ do NS.setSocketOption sock NS.RecvBuffer bufSize
               NS.setSocketOption sock NS.SendBuffer bufSize


   (sock,addr) <- waitEvents $ NS.accept sock

   chs <- liftIO $ newIORef M.empty
--   case addr of
--     NS.SockAddrInet port host -> liftIO $ print("connection from", port, host)
--     NS.SockAddrInet6  a b c d -> liftIO $ print("connection from", a, b,c,d)

   let conn= conn'{closChildren=chs}
   initFinish

   onFinish $ \me -> do
--             return()           !> "onFinish closures receivedd with LISTEN" !> me
             let Connection{closures=closures,closChildren= rmap}= conn
                     -- !> "listenNew closures empty"
             liftIO $ do
                  modifyMVar_ closures $ const $ return M.empty
                  writeIORef rmap M.empty
             killChilds
--             st <- get >>= return . fromJust . parent
--
--             liftIO $ NS.close sock
--             liftIO $ writeIORef (labelth st) (Alive,"")
--             liftIO $ killChildren $ children st -- fromJust $ parent st


   (method,uri, headers) <- receiveHTTPHead sock

   case method of
     "CLOS" ->
          do
--           return ()                          !> "CLOS detected"
           setData $ conn{connData=Just (Node2Node (PortNumber port) sock addr)}
           parallelReadHandler

     _ -> do
           let uri'= BC.tail $ uriPath uri               -- !> "HTTP REQUEST"
           if  "api/" `BC.isPrefixOf` uri'
             then do
                   setData $ conn{connData=Just (Node2Node (PortNumber port)
                                 sock addr)}

                   let log =Exec: (map (Var . IDyns ) $ split $ BC.unpack $ BC.drop 4 uri')

                   return $ SMore (0,0, log )

             else do
                   sconn <- httpMode (method, uri', headers) sock  -- stay serving pages until a websocket request is received

                   setData conn{connData= Just (Node2Web sconn) ,closChildren=chs}
--                   async (return (SMore (0,0,[Exec]))) <|> do
                   do

                     r <-  parallel $ do
                             msg <- WS.receiveData sconn
--                             return () !> ("Server WebSocket msg read",msg)
--                                       !> "<-------<---------<--------------"

                             case reads $ BS.unpack msg of
                               [] -> do
                                   let log =Exec: [Var $ IDynamic  (msg :: BS.ByteString)]
                                   return $ SMore (0,0,log)
                               ((x ,_):_) -> return (x :: StreamData (Int,Int,[LogElem]))

                     case r of
                       SError e -> do
--                           liftIO $ WS.sendClose sconn ("error" :: BS.ByteString)
                           finish (Just e)
--                                                                 !> "FINISH1"
                       _ -> return r



     where
      uriPath = BC.dropWhile (/= '/')
      split []= []
      split ('/':r)= split r
      split s=
          let (h,t) = span (/= '/') s
          in h: split  t





--instance Read PortNumber where
--  readsPrec n str= let [(n,s)]=   readsPrec n str in [(fromIntegral n,s)]


--deriving instance Read PortID
--deriving instance Typeable PortID
#endif

listenResponses :: Loggable a => TransIO (StreamData a)
listenResponses= do

      (conn, node) <- getMailbox
      labelState $ "listen from: "++ show node
      setData conn
#ifndef ghcjs_HOST_OS
      case conn of
             Connection _(Just (Node2Node _ sock _)) _ _ _ _ _ _ -> do
                 input <- liftIO $ SBSL.getContents sock
                 setData $ (ParseContext (error "listenResponses: Parse error") input :: ParseContext BS.ByteString)

#endif
      initFinish
      onFinish $ const $ do
         liftIO $ putStr "removing node: ">> print node
         nodes <- getNodes
         setNodes $ nodes \\ [node]
         killChilds
         let Connection{closures=closures}= conn
         liftIO $ modifyMVar_ closures $ const $ return M.empty


      mread conn


type IdClosure= Int

newtype Closure= Closure IdClosure deriving Show

execLog  mlog = Transient $ do
       case  mlog            of              --  !> ("RECEIVED ", mlog ) of
             SError e -> do
                 runTrans $ finish $ Just e
--                                                                       !> "FINISH2"
                 return Nothing

             SDone   -> runTrans(finish Nothing) >> return Nothing   -- TODO remove closure?
             SMore r -> process r False
             SLast r -> process r True

   where
   process (closl,closr,log) deleteClosure= do
              conn@Connection {closures=closures} <- getData `onNothing` error "Listen: myNode not set"

              if closl== 0 then do

                   setData $ Log True log  $ reverse log
                   setData $ Closure closr

                   return $ Just ()                  --  !> "executing top level closure"

               else do
                 mcont <- liftIO $ modifyMVar closures
                                 $ \map -> return (if deleteClosure then
                                                   M.delete closl map
                                                 else map, M.lookup closl map)
                                                   -- !> ("closures=", M.size map)
                 case mcont of
                   Nothing -> do
                                 runTrans $ msend conn $ SLast (closr,closl, [] :: [()] )
                                    -- to delete the remote closure
                                 error ("request received for non existent closure: "
                                   ++  show closl)
                   -- execute the closure
                   Just (fulLog,cont) -> liftIO $ runStateT (do
                                     let nlog= reverse log ++  fulLog
                                     setData $ Log True  log  nlog

                                     setData $ Closure closr
--                                                                !> ("SETCLOSURE",closr)
                                     runCont cont) cont
--                                                                !> ("executing closure",closl)


                 return Nothing
--                                                                  !> "FINISH CLOSURE"

#ifdef ghcjs_HOST_OS
listen node = onAll $ do
        addNodes [node]

        events <- liftIO $ newIORef M.empty

        conn <-  defConnection >>= \c -> return c{myNode=node,comEvent=events}
        setData conn
        r <- listenResponses
        execLog  r
#endif

type Pool= [Connection]
type Package= String
type Program= String
type Service= (Package, Program)


-- * Level 2: connections node lists and operations with the node list


{-# NOINLINE emptyPool #-}
emptyPool :: MonadIO m => m (MVar Pool)
emptyPool= liftIO $ newMVar  []


createNodeServ ::  HostName -> Integer -> [Service] -> IO Node
createNodeServ h p svs= do
    pool <- emptyPool
    return $ Node h ( fromInteger p) pool svs




createNode :: HostName -> Integer -> IO Node
createNode h p= createNodeServ h p []

createWebNode :: IO Node
createWebNode= do
  pool <- emptyPool
  return $ Node "webnode" ( fromInteger 0) pool  [("webnode","")]


instance Eq Node where
    Node h p _ _ ==Node h' p' _ _= h==h' && p==p'


instance Show Node where
    show (Node h p _ servs )= show (h,p, servs)



instance Read Node where

    readsPrec _ s=
          let r= readsPrec' 0 s
          in case r of
            [] -> []
            [((h,p,ss),s')] ->  [(Node h p empty
              ( ss),s')]
          where
          empty= unsafePerformIO  emptyPool


-- #ifndef ghcjs_HOST_OS
--instance Read NS.SockAddr where
--    readsPrec _ ('[':s)=
--       let (s',r1)= span (/=']')  s
--           [(port,r)]= readsPrec 0 $ tail $ tail r1
--       in [(NS.SockAddrInet6 port 0 (IP.toHostAddress6 $  read s') 0, r)]
--    readsPrec _ s=
--       let (s',r1)= span(/= ':') s
--           [(port,r)]= readsPrec 0 $ tail r1
--       in [(NS.SockAddrInet port (IP.toHostAddress $  read s'),r)]
-- #endif

--newtype MyNode= MyNode Node deriving(Read,Show,Typeable)


--instance Indexable MyNode where key (MyNode Node{nodePort=port}) =  "MyNode "++ show port
--
--instance Serializable MyNode where
--    serialize= BS.pack . show
--    deserialize= read . BS.unpack

nodeList :: TVar  [Node]
nodeList = unsafePerformIO $ newTVarIO []

deriving instance Ord PortID

--myNode :: Int -> DBRef  MyNode
--myNode= getDBRef $ key $ MyNode undefined



errorMyNode f= error $ f ++ ": Node not set. initialize it with connect, listen, initNode..."


getMyNode :: TransIO Node -- (MonadIO m, MonadState EventF m) => m Node
getMyNode =  do
    Connection{myNode= node}  <- getSData   <|> errorMyNode "getMyNode" :: TransIO Connection
    return node



-- | return the list of nodes connected to the local node
getNodes :: MonadIO m => m [Node]
getNodes  = liftIO $ atomically $ readTVar  nodeList

-- | add nodes to the list of nodes
addNodes :: [Node] ->  TransIO () -- (MonadIO m, MonadState EventF m) => [Node] -> m ()
addNodes   nodes=  do
  my <- getMyNode    -- mynode must be first
  liftIO . atomically $ do
    prevnodes <- readTVar nodeList

    writeTVar nodeList $ my: (( nub $ nodes ++ prevnodes) \\[my])

-- | set the list of nodes
setNodes nodes= liftIO $ atomically $ writeTVar nodeList $  nodes


shuffleNodes :: MonadIO m => m [Node]
shuffleNodes=  liftIO . atomically $ do
  nodes <- readTVar nodeList
  let nodes'= tail nodes ++ [head nodes]
  writeTVar nodeList nodes'
  return nodes'

--getInterfaces :: TransIO TransIO HostName
--getInterfaces= do
--   host <- logged $ do
--      ifs <- liftIO $ getNetworkInterfaces
--      liftIO $ mapM_ (\(i,n) ->putStrLn $ show i ++ "\t"++  show (ipv4 n) ++ "\t"++name n)$ zip [0..] ifs
--      liftIO $ putStrLn "Select one: "
--      ind <-  input ( < length ifs)
--      return $ show . ipv4 $ ifs !! ind


-- | execute a Transient action in each of the nodes connected.
--
-- The response of each node is received by the invoking node and processed by the rest of the procedure.
-- By default, each response is processed in a new thread. To restrict the number of threads
-- use the thread control primitives.
--
-- this snippet receive a message from each of the simulated nodes:
--
-- > main = keep $ do
-- >    let nodes= map createLocalNode [2000..2005]
-- >    addNodes nodes
-- >    (foldl (<|>) empty $ map listen nodes) <|> return ()
-- >
-- >    r <- clustered $ do
-- >               Connection (Just(PortNumber port, _, _, _)) _ <- getSData
-- >               return $ "hi from " ++ show port++ "\n"
-- >    liftIO $ putStrLn r
-- >    where
-- >    createLocalNode n= createNode "localhost" (PortNumber n)
clustered :: Loggable a  => Cloud a -> Cloud a
clustered proc= callNodes (<|>) empty proc


-- A variant of `clustered` that wait for all the responses and `mappend` them
mclustered :: (Monoid a, Loggable a)  => Cloud a -> Cloud a
mclustered proc= callNodes (<>) mempty proc


callNodes op init proc= loggedc' $ do
    nodes <-  local getNodes
    let nodes' = filter (not . isWebNode) nodes
    foldr op init $ map (\node -> runAt node proc) nodes'
    where
    isWebNode Node {nodeServices=srvs}
         | ("webnode","") `elem` srvs = True
         | otherwise = False

-- | set the rest of the computation as a new node (first parameter) and connect it
-- to an existing node (second parameter). then it uses `connect`` to synchronize the list of nodes

connect ::  Node ->  Node -> Cloud ()

#ifndef ghcjs_HOST_OS
connect  node  remotenode =   do
    listen node <|> return () -- listen1 node remotenode
    connect' remotenode

-- | synchronize the list of nodes with a remote node and all the nodes connected to it
-- the final effect is that all the nodes reachable share the same list of nodes
connect'  remotenode= do
    nodes <- local getNodes
    local $ liftIO $ putStrLn $ "connecting to: "++ show remotenode

    newNodes <- runAt remotenode $ do
           local $ do
              conn@(Connection _(Just (Node2Node _ _ _)) _ _ _ _ _ _) <- getSData <|>
               error ("connect': need to be connected to a node: use wormhole/connect/listen")
              let nodeConnecting= head nodes
              liftIO $ modifyMVar_ (connection nodeConnecting) $ const $ return [conn]

              onFinish . const $ do
                   liftIO $ putStrLn "removing node: ">> print nodeConnecting
                   nodes <- getNodes
                   setNodes $ nodes \\ [nodeConnecting]

              return nodes

           mclustered . local . addNodes $ nodes



           local $ do
               allNodes <- getNodes
               liftIO $ putStrLn "Known nodes: " >> print  allNodes
               return allNodes

    let n = newNodes \\ nodes
    when (not $ null n) $ mclustered $ local $ addNodes n   -- add the new discovered nodes

    local $ do
        addNodes  nodes
        nodes <- getNodes
        liftIO $ putStrLn  "Known nodes: " >> print nodes


#else
connect _ _= empty
connect' _ = empty
#endif


--------------------------------------------



#ifndef ghcjs_HOST_OS

readFrom :: Socket         -- ^ Connected socket
            -> IO BS.ByteString  -- ^ Data received
readFrom sock =  loop where
-- do
--    s <- SBS.recv sock 40980
--    BLC.Chunk <$> return s <*> return  BLC.Empty
  loop = unsafeInterleaveIO $ do
    s <- SBS.recv sock 4098
    if BC.null s
      then  return BLC.Empty  -- !>  "EMPTY SOCK"
      else BLC.Chunk s `liftM` loop

toStrict= B.concat . BS.toChunks

httpMode (method,uri, headers) sock  = do
--   return ()                        !> ("HTTP request",method,uri, headers)
   if isWebSocketsReq headers
     then  liftIO $ do

         stream <- makeStream                  -- !!> "WEBSOCKETS request"
            (do
                bs <-  SBS.recv sock 4096 -- readFrom sock
                return $ if BC.null bs then Nothing else Just  bs)
            (\mbBl -> case mbBl of
                Nothing -> return ()
                Just bl ->  SBS.sendMany sock (BL.toChunks bl) >> return())   -- !!> show ("SOCK RESP",bl)

         let
             pc = WS.PendingConnection
                { WS.pendingOptions     = WS.defaultConnectionOptions
                , WS.pendingRequest     = NWS.RequestHead  uri  headers False -- RequestHead (BC.pack $ show uri)
                                                      -- (map parseh headers) False
                , WS.pendingOnAccept    = \_ -> return ()
                , WS.pendingStream      = stream
                }


         sconn    <- WS.acceptRequest pc               -- !!> "accept request"
         WS.forkPingThread sconn 30
         return sconn



     else do

        let file= if BC.null uri then "index.html" else uri
        {- TODO renderin in server
           NEEDED:  recodify View to use blaze-html in server. wlink to get path in server
           does file exist?
           if exist, send else do
              store path, execute continuation
              get the rendering
              send trough HTTP

        -}
        content <- liftIO $  BL.readFile ( "./static/out.jsexe/"++ BC.unpack file)
                                `catch` (\(e:: SomeException) ->
                                    return  "Not found file: index.html<br/> please compile with ghcjs<br/> ghcjs program.hs -o static/out")
        liftIO $ SBS.sendMany sock $
          ["HTTP/1.0 200 OK\nContent-Type: text/html\nConnection: close\nContent-Length: "
          <> BC.pack (show $ BL.length content) <>"\n\n"] ++
                                      (BL.toChunks content )
        empty


--counter=  unsafePerformIO $ newMVar 0
api :: TransIO BS.ByteString -> Cloud ()
api  w= Cloud  $ do
   conn <- getSData  <|> error "api: Need a connection opened with initNode, listen, simpleWebApp"
   r <-  w

   send conn r                         --  !> r
   empty

   where
   send (Connection _(Just (Node2Web  sconn )) _ _ _ _ _ _) r=
      liftIO $   WS.sendTextData sconn  r   -- !> ("NOde2Web",r)

   send (Connection _(Just (Node2Node _ sock _)) _ _ blocked _ _ _) r=
      liftIO $   withMVar blocked $ const $  SBS.sendMany sock
                                      (BL.toChunks r )  --  !> ("NOde2Node",r)
--


data ParseContext a = IsString a => ParseContext (IO  a) a deriving Typeable


--giveData s= do
--    r <- readFrom s     -- 80000
--    return r               -- !> ( "giveData ", r)


isWebSocketsReq = not  . null
    . filter ( (== mk "Sec-WebSocket-Key") . fst)



receiveHTTPHead s = do
  input <-  liftIO $ SBSL.getContents s

  setData $ (ParseContext (error "request truncated. Maybe the browser program does not match the server one. \nRecompile the program again with ghcjs <program.hs>  -o static/out") input
             ::ParseContext BS.ByteString)
  (method, uri, vers) <- (,,) <$> getMethod <*> getUri <*> getVers
  headers <- many $ (,) <$> (mk <$> getParam) <*> getParamValue    -- !>  (method, uri, vers)
  return (method, toStrict uri, headers)                           -- !>  (method, uri, headers)

  where

  getMethod= getString
  getUri= getString
  getVers= getString
  getParam= do
      dropSpaces
      r <- tTakeWhile (\x -> x /= ':' && not (endline x))
      if BS.null r || r=="\r"  then  empty  else  dropChar >> return(toStrict r)

  getParamValue= toStrict <$> ( dropSpaces >> tTakeWhile  (\x -> not (endline x)))




dropSpaces= parse $ \str ->((),BS.dropWhile isSpace str)

dropChar= parse  $ \r -> ((), BS.tail r)

endline c= c== '\n' || c =='\r'

--tGetLine= tTakeWhile . not . endline




parallelReadHandler :: Loggable a => TransIO (StreamData a)
parallelReadHandler= do
      ParseContext readit str <- getSData <|> error "parallelReadHandler: ParseContext not found"
                                        :: (TransIO (ParseContext BS.ByteString))
--      r <-  choose $ readStream str
      rest <- liftIO $ newIORef $ BS.unpack str
      r <- parallel $ readStream' rest
      return r
--                !> ("read",r)
--                !> "<-------<----------<--------<----------"
    where
    readStream' :: (Loggable a) =>  IORef String  -> IO(StreamData a)
    readStream' rest = do
       s <- readIORef rest
       [(x,r)] <- maybeRead  s
       writeIORef rest r
       return x

--    readStream :: (Typeable a, Read a) =>  BS.ByteString -> [StreamData a]
--    readStream s=  readStream1 $ BS.unpack s
--     where
--
--     readStream1 s=
--       let [(x,r)] = maybeRead  s
--       in  x : readStream1 r


    maybeRead line= do
         let [(v,left)] = reads  line
--         print v
         (v   `seq` return [(v,left)])
--                        `catch` (\(e::SomeException) -> do
--                          liftIO $ print  $ "******readStream ERROR in: "++take 100 line
--                          maybeRead left)


getString= do
    dropSpaces
    tTakeWhile (not . isSpace)

tTakeWhile :: (Char -> Bool) -> TransIO BS.ByteString
tTakeWhile cond= parse (BS.span cond)


parse :: Monoid b => (BS.ByteString -> (b, BS.ByteString)) -> TransIO b
parse split= do
     ParseContext readit str <- getSData
                                <|> error "parse: ParseContext not found"
                                :: TransIO (ParseContext BS.ByteString)
--    if  str == mempty
--     then do
--          error "READIT ERROR*******" -- str3 <- liftIO  readit
--
--          setData $ ParseContext readit str3                     -- !> str3

     if str== mempty   then empty   -- else  parse split
     else if BS.take 2 str =="\n\n"  then do setData $ ParseContext readit  (BS.drop 2 str) ; empty
     else if BS.take 4 str== "\r\n\r\n" then do setData $ ParseContext readit  (BS.drop 4 str) ; empty
     else do

          let (ret,str3) = split str
          setData $ ParseContext readit str3

          if str3== mempty
            then   return ret  <> (parse split <|> return mempty)

            else   return ret




#endif



#ifdef ghcjs_HOST_OS
isBrowserInstance= True
api _= empty
#else
-- | True if it is running in the browser
isBrowserInstance= False

#endif
