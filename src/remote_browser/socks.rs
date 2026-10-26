use hbb_common::{
    anyhow::{anyhow, bail},
    log,
    tokio::{
        self,
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
        task::{JoinHandle, JoinSet},
        time::{timeout, Duration},
    },
    ResultType,
};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CONNECTIONS: usize = 128;

/// The listener and all accepted sockets belong to one authenticated RustDesk session.
pub struct BrowserProxy {
    pub address: SocketAddr,
    task: JoinHandle<()>,
}

impl BrowserProxy {
    pub async fn start(token: String) -> ResultType<Self> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let address = listener.local_addr()?;
        let task = tokio::spawn(async move {
            let mut connections = JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => match accepted {
                        Ok((socket, _)) if connections.len() < MAX_CONNECTIONS => {
                            let token = token.clone();
                            connections.spawn(async move {
                                if let Err(error) = serve(socket, &token).await {
                                    log::trace!("browser proxy connection ended: {}", error);
                                }
                            });
                        }
                        Ok(_) => {}
                        Err(error) => {
                            log::warn!("browser proxy listener failed: {}", error);
                            break;
                        }
                    },
                    result = connections.join_next(), if !connections.is_empty() => {
                        if let Some(Err(error)) = result {
                            log::trace!("browser proxy task ended: {}", error);
                        }
                    }
                }
            }
        });
        Ok(Self { address, task })
    }
}

impl Drop for BrowserProxy {
    fn drop(&mut self) {
        // Dropping the task's JoinSet cancels accepted sockets as well as the listener.
        self.task.abort();
    }
}

async fn serve(mut socket: TcpStream, token: &str) -> ResultType<()> {
    let (mut remote, loopback) = timeout(HANDSHAKE_TIMEOUT, handshake(&mut socket, token)).await??;
    if loopback {
        return super::loopback::relay(socket, remote).await;
    }
    tokio::io::copy_bidirectional(&mut socket, &mut remote).await?;
    Ok(())
}

async fn reply(socket: &mut TcpStream, status: u8) -> ResultType<()> {
    socket
        .write_all(&[5, status, 0, 1, 0, 0, 0, 0, 0, 0])
        .await?;
    Ok(())
}

async fn handshake(socket: &mut TcpStream, token: &str) -> ResultType<(TcpStream, bool)> {
    let version = socket.read_u8().await?;
    let methods_len = socket.read_u8().await?;
    let mut methods = vec![0; methods_len as usize];
    socket.read_exact(&mut methods).await?;
    if version != 5 || !methods.contains(&2) {
        socket.write_all(&[5, 255]).await?;
        bail!("SOCKS5 username/password authentication required");
    }
    socket.write_all(&[5, 2]).await?;
    let auth_version = socket.read_u8().await?;
    let username_len = socket.read_u8().await?;
    let mut username = vec![0; username_len as usize];
    socket.read_exact(&mut username).await?;
    let password_len = socket.read_u8().await?;
    let mut password = vec![0; password_len as usize];
    socket.read_exact(&mut password).await?;
    if auth_version != 1
        || username != super::SOCKS_USERNAME.as_bytes()
        || password != token.as_bytes()
    {
        socket.write_all(&[1, 1]).await?;
        bail!("SOCKS5 authentication failed");
    }
    socket.write_all(&[1, 0]).await?;
    let mut header = [0; 4];
    socket.read_exact(&mut header).await?;
    if header[0] != 5 || header[1] != 1 || header[2] != 0 {
        reply(socket, 7).await?;
        bail!("Only SOCKS5 TCP CONNECT is supported");
    }
    let host = match header[3] {
        1 => {
            let mut bytes = [0; 4];
            socket.read_exact(&mut bytes).await?;
            IpAddr::V4(Ipv4Addr::from(bytes)).to_string()
        }
        4 => {
            let mut bytes = [0; 16];
            socket.read_exact(&mut bytes).await?;
            IpAddr::V6(Ipv6Addr::from(bytes)).to_string()
        }
        3 => {
            let len = socket.read_u8().await?;
            let mut bytes = vec![0; len as usize];
            socket.read_exact(&mut bytes).await?;
            String::from_utf8(bytes)?
        }
        _ => {
            reply(socket, 8).await?;
            bail!("Unsupported SOCKS5 address type");
        }
    };
    let port = socket.read_u16().await?;
    if port == 0 || host.is_empty() || host.as_bytes().contains(&0) {
        reply(socket, 8).await?;
        bail!("Invalid SOCKS5 target");
    }
    let loopback = match super::loopback::target(&host) {
        Ok(target) => target,
        Err(error) => {
            reply(socket, 8).await?;
            return Err(error);
        }
    };
    match TcpStream::connect((loopback.unwrap_or(host.as_str()), port)).await {
        Ok(remote) => {
            reply(socket, 0).await?;
            Ok((remote, loopback.is_some()))
        }
        Err(error) => {
            reply(socket, 5).await?;
            Err(anyhow!("Browser target connection failed: {}", error))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "5981d37d-1094-4217-9e43-23e51365304c";

    async fn authenticate(proxy: &BrowserProxy, password: &str) -> (TcpStream, [u8; 2]) {
        let mut socket = TcpStream::connect(proxy.address).await.unwrap();
        socket.write_all(&[5, 2, 0, 2]).await.unwrap();
        let mut reply = [0; 2];
        socket.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply, [5, 2]);
        let mut auth = vec![1, super::super::SOCKS_USERNAME.len() as u8];
        auth.extend_from_slice(super::super::SOCKS_USERNAME.as_bytes());
        auth.push(password.len() as u8);
        auth.extend_from_slice(password.as_bytes());
        socket.write_all(&auth).await.unwrap();
        socket.read_exact(&mut reply).await.unwrap();
        (socket, reply)
    }

    async fn connect(proxy: &BrowserProxy, port: u16) -> TcpStream {
        let (mut socket, auth) = authenticate(proxy, TOKEN).await;
        assert_eq!(auth, [1, 0]);
        let mut request = vec![5, 1, 0, 3, 9];
        request.extend_from_slice(b"localhost");
        request.extend_from_slice(&port.to_be_bytes());
        socket.write_all(&request).await.unwrap();
        let mut reply = [0; 10];
        socket.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply[1], 0);
        socket
    }

    async fn connect_alias(proxy: &BrowserProxy, port: u16) -> TcpStream {
        let (mut socket, auth) = authenticate(proxy, TOKEN).await;
        assert_eq!(auth, [1, 0]);
        let host = b"localhost.rustdesk.localhost";
        let mut request = vec![5, 1, 0, 3, host.len() as u8];
        request.extend_from_slice(host);
        request.extend_from_slice(&port.to_be_bytes());
        socket.write_all(&request).await.unwrap();
        let mut reply = [0; 10];
        socket.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply[1], 0);
        socket
    }

    #[tokio::test]
    async fn synthetic_localhost_preserves_ajax_body_cookies_and_cors() {
        use hbb_common::tokio::io::{AsyncBufReadExt, BufReader};
        let proxy = BrowserProxy::start(TOKEN.to_owned()).await.unwrap();
        let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let port = target.local_addr().unwrap().port();
        let mut browser = connect_alias(&proxy, port).await;
        let (server, _) = target.accept().await.unwrap();
        let request = format!("POST /api HTTP/1.1\r\nHost: localhost.rustdesk.localhost:{port}\r\nOrigin: http://localhost.rustdesk.localhost:{port}\r\nContent-Length: 4\r\n\r\nping");
        browser.write_all(request.as_bytes()).await.unwrap();
        let mut server = BufReader::new(server);
        let mut received = String::new();
        loop {
            let mut line = String::new();
            server.read_line(&mut line).await.unwrap();
            if line == "\r\n" { break; }
            received.push_str(&line);
        }
        assert!(received.contains(&format!("Host: localhost:{port}\r\n")));
        assert!(received.contains(&format!("Origin: http://localhost:{port}\r\n")));
        let mut body = [0; 4];
        server.read_exact(&mut body).await.unwrap();
        assert_eq!(&body, b"ping");
        server.write_all(format!("HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: http://localhost:{port}\r\nSet-Cookie: session=dev; Domain=localhost; Path=/\r\nContent-Length: 4\r\n\r\npong").as_bytes()).await.unwrap();
        drop(server);
        let mut response = String::new();
        timeout(Duration::from_secs(2), browser.read_to_string(&mut response)).await.unwrap().unwrap();
        assert!(response.contains(&format!("Access-Control-Allow-Origin: http://localhost.rustdesk.localhost:{port}\r\n")));
        assert!(response.contains("Domain=localhost.rustdesk.localhost; Path=/"));
        assert!(response.ends_with("\r\n\r\npong"));
    }

    #[tokio::test]
    async fn synthetic_localhost_keeps_websocket_upgrade_and_frames() {
        let proxy = BrowserProxy::start(TOKEN.to_owned()).await.unwrap();
        let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let mut browser = connect_alias(&proxy, target.local_addr().unwrap().port()).await;
        let (mut server, _) = target.accept().await.unwrap();
        browser.write_all(b"GET /hmr HTTP/1.1\r\nHost: localhost.rustdesk.localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n").await.unwrap();
        let mut request = vec![0; 512];
        let n = server.read(&mut request).await.unwrap();
        let request = String::from_utf8_lossy(&request[..n]);
        assert!(request.contains("Host: localhost\r\n"));
        assert!(request.contains("Connection: Upgrade\r\n"));
        let upgrade = b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n\x81\x02ok";
        server.write_all(upgrade).await.unwrap();
        let mut received = vec![0; upgrade.len()];
        timeout(Duration::from_secs(2), browser.read_exact(&mut received)).await.unwrap().unwrap();
        assert_eq!(received, upgrade);
        browser.write_all(b"\x81\x02hi").await.unwrap();
        let mut frame = [0; 4];
        timeout(Duration::from_secs(2), server.read_exact(&mut frame)).await.unwrap().unwrap();
        assert_eq!(&frame, b"\x81\x02hi");
    }

    #[tokio::test]
    async fn refuses_missing_and_wrong_session_credentials() {
        let proxy = BrowserProxy::start(TOKEN.to_owned()).await.unwrap();
        assert_eq!(authenticate(&proxy, "another-session").await.1, [1, 1]);
        let mut unauthenticated = TcpStream::connect(proxy.address).await.unwrap();
        unauthenticated.write_all(&[5, 1, 0]).await.unwrap();
        let mut reply = [0; 2];
        unauthenticated.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply, [5, 255]);
    }

    #[tokio::test]
    async fn localhost_http_and_sse_stream_before_target_closes() {
        let proxy = BrowserProxy::start(TOKEN.to_owned()).await.unwrap();
        let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let mut browser = connect(&proxy, target.local_addr().unwrap().port()).await;
        let (mut server, _) = target.accept().await.unwrap();
        let request = b"GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n";
        browser.write_all(request).await.unwrap();
        let mut received = vec![0; request.len()];
        server.read_exact(&mut received).await.unwrap();
        assert_eq!(received, request);
        let event =
            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: hot reload\n\n";
        server.write_all(event).await.unwrap();
        let mut response = vec![0; event.len()];
        timeout(Duration::from_secs(2), browser.read_exact(&mut response))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(response, event);
    }

    #[tokio::test]
    async fn websocket_upgrade_bytes_and_session_teardown() {
        let proxy = BrowserProxy::start(TOKEN.to_owned()).await.unwrap();
        let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let mut browser = connect(&proxy, target.local_addr().unwrap().port()).await;
        let (mut server, _) = target.accept().await.unwrap();
        let upgrade = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n\x81\x03hmr";
        server.write_all(upgrade).await.unwrap();
        let mut response = vec![0; upgrade.len()];
        browser.read_exact(&mut response).await.unwrap();
        assert_eq!(response, upgrade);
        browser
            .write_all(b"\x81\x82\x01\x02\x03\x04ok")
            .await
            .unwrap();
        let mut frame = [0; 8];
        server.read_exact(&mut frame).await.unwrap();
        assert_eq!(&frame, b"\x81\x82\x01\x02\x03\x04ok");
        drop(proxy);
        assert_eq!(
            timeout(Duration::from_secs(2), browser.read_u8())
                .await
                .unwrap()
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::UnexpectedEof
        );
        assert_eq!(
            timeout(Duration::from_secs(2), server.read_u8())
                .await
                .unwrap()
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::UnexpectedEof
        );
    }
}
