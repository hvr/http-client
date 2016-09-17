{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
-- | Support for making connections via the connection package and, in turn,
-- the tls package suite.
--
-- Recommended reading: <https://haskell-lang.org/library/http-client>
module Network.HTTP.Client.TLS
    ( -- * Settings
      tlsManagerSettings
    , mkManagerSettings
    , mkManagerSettingsContext
      -- * Digest authentication
    , applyDigestAuth
    , DigestAuthException (..)
    , DigestAuthExceptionDetails (..)
      -- * Global manager
    , getGlobalManager
    , setGlobalManager
    ) where

import Data.Default.Class
import Network.HTTP.Client hiding (host, port)
import Network.HTTP.Client.Internal hiding (host, port)
import Control.Exception
import qualified Network.Connection as NC
import Network.Socket (HostAddress)
import qualified Network.TLS as TLS
import qualified Data.ByteString as S
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad (guard, unless)
import qualified Data.CaseInsensitive as CI
import Data.Maybe (fromMaybe, isJust)
import Network.HTTP.Types (status401)
import Crypto.Hash (hash, Digest, MD5)
import Control.Arrow ((***))
import Data.ByteArray.Encoding (convertToBase, Base (Base16))
import Data.Typeable (Typeable)
import Control.Monad.Catch (MonadThrow, throwM)

-- | Create a TLS-enabled 'ManagerSettings' with the given 'NC.TLSSettings' and
-- 'NC.SockSettings'
mkManagerSettings :: NC.TLSSettings
                  -> Maybe NC.SockSettings
                  -> ManagerSettings
mkManagerSettings = mkManagerSettingsContext Nothing

-- | Same as 'mkManagerSettings', but also takes an optional
-- 'NC.ConnectionContext'. Providing this externally can be an
-- optimization, though that may change in the future. For more
-- information, see:
--
-- <https://github.com/snoyberg/http-client/pull/227>
--
-- @since 0.3.2
mkManagerSettingsContext
    :: Maybe NC.ConnectionContext
    -> NC.TLSSettings
    -> Maybe NC.SockSettings
    -> ManagerSettings
mkManagerSettingsContext mcontext tls sock = defaultManagerSettings
    { managerTlsConnection = getTlsConnection mcontext (Just tls) sock
    , managerTlsProxyConnection = getTlsProxyConnection mcontext tls sock
    , managerRawConnection =
        case sock of
            Nothing -> managerRawConnection defaultManagerSettings
            Just _ -> getTlsConnection mcontext Nothing sock
    , managerRetryableException = \e ->
        case () of
            ()
                | ((fromException e)::(Maybe TLS.TLSError))==Just TLS.Error_EOF -> True
                | otherwise -> managerRetryableException defaultManagerSettings e
    , managerWrapException = \req ->
        let wrapper se =
                case fromException se of
                    Just (_ :: IOException) -> se'
                    Nothing -> case fromException se of
                      Just TLS.Terminated{} -> se'
                      Just TLS.HandshakeFailed{} -> se'
                      Just TLS.ConnectionNotEstablished -> se'
                      _ -> se
              where
                se' = toException $ HttpExceptionRequest req $ InternalException se
         in handle $ throwIO . wrapper
    }

-- | Default TLS-enabled manager settings
tlsManagerSettings :: ManagerSettings
tlsManagerSettings = mkManagerSettings def Nothing

getTlsConnection :: Maybe NC.ConnectionContext
                 -> Maybe NC.TLSSettings
                 -> Maybe NC.SockSettings
                 -> IO (Maybe HostAddress -> String -> Int -> IO Connection)
getTlsConnection mcontext tls sock = do
    context <- maybe NC.initConnectionContext return mcontext
    return $ \_ha host port -> do
        conn <- NC.connectTo context NC.ConnectionParams
            { NC.connectionHostname = host
            , NC.connectionPort = fromIntegral port
            , NC.connectionUseSecure = tls
            , NC.connectionUseSocks = sock
            }
        convertConnection conn

getTlsProxyConnection
    :: Maybe NC.ConnectionContext
    -> NC.TLSSettings
    -> Maybe NC.SockSettings
    -> IO (S.ByteString -> (Connection -> IO ()) -> String -> Maybe HostAddress -> String -> Int -> IO Connection)
getTlsProxyConnection mcontext tls sock = do
    context <- maybe NC.initConnectionContext return mcontext
    return $ \connstr checkConn serverName _ha host port -> do
        --error $ show (connstr, host, port)
        conn <- NC.connectTo context NC.ConnectionParams
            { NC.connectionHostname = serverName
            , NC.connectionPort = fromIntegral port
            , NC.connectionUseSecure = Nothing
            , NC.connectionUseSocks =
                case sock of
                    Just _ -> error "Cannot use SOCKS and TLS proxying together"
                    Nothing -> Just $ NC.OtherProxy host $ fromIntegral port
            }

        NC.connectionPut conn connstr
        conn' <- convertConnection conn

        checkConn conn'

        NC.connectionSetSecure context conn tls

        return conn'

convertConnection :: NC.Connection -> IO Connection
convertConnection conn = makeConnection
    (NC.connectionGetChunk conn)
    (NC.connectionPut conn)
    -- Closing an SSL connection gracefully involves writing/reading
    -- on the socket.  But when this is called the socket might be
    -- already closed, and we get a @ResourceVanished@.
    (NC.connectionClose conn `Control.Exception.catch` \(_ :: IOException) -> return ())

-- | Evil global manager, to make life easier for the common use case
globalManager :: IORef Manager
globalManager = unsafePerformIO (newManager tlsManagerSettings >>= newIORef)
{-# NOINLINE globalManager #-}

-- | Get the current global 'Manager'
--
-- @since 0.2.4
getGlobalManager :: IO Manager
getGlobalManager = readIORef globalManager
{-# INLINE getGlobalManager #-}

-- | Set the current global 'Manager'
--
-- @since 0.2.4
setGlobalManager :: Manager -> IO ()
setGlobalManager = writeIORef globalManager

-- | Generated by 'applyDigestAuth' when it is unable to apply the
-- digest credentials to the request.
--
-- @since 0.3.3
data DigestAuthException
    = DigestAuthException Request (Response ()) DigestAuthExceptionDetails
    deriving (Show, Typeable)
instance Exception DigestAuthException

-- | Detailed explanation for failure for 'DigestAuthException'
--
-- @since 0.3.3
data DigestAuthExceptionDetails
    = UnexpectedStatusCode
    | MissingWWWAuthenticateHeader
    | WWWAuthenticateIsNotDigest
    | MissingRealm
    | MissingNonce
    deriving (Show, Typeable)

-- | Apply digest authentication to this request.
--
-- Note that this function will need to make an HTTP request to the
-- server in order to get the nonce, thus the need for a @Manager@ and
-- to live in @IO@. This also means that the request body will be sent
-- to the server. If the request body in the supplied @Request@ can
-- only be read once, you should replace it with a dummy value.
--
-- In the event of successfully generating a digest, this will return
-- a @Just@ value. If there is any problem with generating the digest,
-- it will return @Nothing@.
--
-- @since 0.3.1
applyDigestAuth :: (MonadIO m, MonadThrow n)
                => S.ByteString -- ^ username
                -> S.ByteString -- ^ password
                -> Request
                -> Manager
                -> m (n Request)
applyDigestAuth user pass req man = liftIO $ do
    res <- httpNoBody req man
    let throw' = throwM . DigestAuthException req res
    return $ do
        unless (responseStatus res == status401)
            $ throw' UnexpectedStatusCode
        h1 <- maybe (throw' MissingWWWAuthenticateHeader) return
            $ lookup "WWW-Authenticate" $ responseHeaders res
        h2 <- maybe (throw' WWWAuthenticateIsNotDigest) return
            $ stripCI "Digest " h1
        let pieces = map (strip *** strip) (toPairs h2)
        realm <- maybe (throw' MissingRealm) return
               $ lookup "realm" pieces
        nonce <- maybe (throw' MissingNonce) return
               $ lookup "nonce" pieces
        let qop = isJust $ lookup "qop" pieces
            digest
                | qop = md5 $ S.concat
                    [ ha1
                    , ":"
                    , nonce
                    , ":00000001:deadbeef:auth:"
                    , ha2
                    ]
                | otherwise = md5 $ S.concat [ha1, ":", nonce, ":", ha2]
              where
                ha1 = md5 $ S.concat [user, ":", realm, ":", pass]

                -- we always use no qop or qop=auth
                ha2 = md5 $ S.concat [method req, ":", path req]

                md5 bs = convertToBase Base16 (hash bs :: Digest MD5)
            key = "Authorization"
            val = S.concat
                [ "Digest username=\""
                , user
                , "\", realm=\""
                , realm
                , "\", nonce=\""
                , nonce
                , "\", uri=\""
                , path req
                , "\", response=\""
                , digest
                , "\""
                -- FIXME algorithm?
                , case lookup "opaque" pieces of
                    Nothing -> ""
                    Just o -> S.concat [", opaque=\"", o, "\""]
                , if qop
                    then ", qop=auth, nc=00000001, cnonce=\"deadbeef\""
                    else ""
                ]
        return req
            { requestHeaders = (key, val)
                             : filter
                                    (\(x, _) -> x /= key)
                                    (requestHeaders req)
            , cookieJar = Just $ responseCookieJar res
            }
  where
    stripCI x y
        | CI.mk x == CI.mk (S.take len y) = Just $ S.drop len y
        | otherwise = Nothing
      where
        len = S.length x

    _comma = 44
    _equal = 61
    _dquot = 34
    _space = 32

    strip = fst . S.spanEnd (== _space) . S.dropWhile (== _space)

    toPairs bs0
        | S.null bs0 = []
        | otherwise =
            let bs1 = S.dropWhile (== _space) bs0
                (key, bs2) = S.break (\w -> w == _equal || w == _comma) bs1
             in case () of
                  ()
                    | S.null bs2 -> [(key, "")]
                    | S.head bs2 == _equal ->
                        let (val, rest) = parseVal $ S.tail bs2
                         in (key, val) : toPairs rest
                    | otherwise ->
                        assert (S.head bs2 == _comma) $
                        (key, "") : toPairs (S.tail bs2)

    parseVal bs0 = fromMaybe (parseUnquoted bs0) $ do
        guard $ not $ S.null bs0
        guard $ S.head bs0 == _dquot
        let (x, y) = S.break (== _dquot) $ S.tail bs0
        guard $ not $ S.null y
        Just (x, S.drop 1 $ S.dropWhile (/= _comma) y)

    parseUnquoted bs =
        let (x, y) = S.break (== _comma) bs
         in (x, S.drop 1 y)
