use crate::{
    client::{hc_connection, Client, Data, Interface},
    port_forward_mux::Tunnel,
    ui_session_interface::{InvokeUiSession, Session},
};
use base::message_proto::{login_response, message, Message};
use hbb_common::{
    anyhow::{anyhow, bail},
    config::READ_TIMEOUT,
    protobuf::Message as _,
    rendezvous_proto::ConnType,
    tokio::{self, net::TcpListener, sync::mpsc, time::timeout},
    ResultType,
};
use std::{net::TcpListener as StdTcpListener, sync::Mutex};

pub struct BrowserClient {
    listener: Mutex<Option<StdTcpListener>>,
    pub port: u16,
    pub token: String,
    notify: Box<dyn Fn(&str) + Send + Sync>,
}

impl BrowserClient {
    pub fn prepare(notify: impl Fn(&str) + Send + Sync + 'static) -> ResultType<Self> {
        let listener = StdTcpListener::bind("127.0.0.1:0")?;
        listener.set_nonblocking(true)?;
        Ok(Self {
            port: listener.local_addr()?.port(),
            listener: Mutex::new(Some(listener)),
            token: uuid::Uuid::new_v4().to_string(),
            notify: Box::new(notify),
        })
    }

    pub async fn run<T: InvokeUiSession>(
        &self,
        handler: Session<T>,
        mut receiver: mpsc::UnboundedReceiver<Data>,
        key: &str,
        token: &str,
    ) -> ResultType<()> {
        let listener = self
            .listener
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| anyhow!("Browser session already started"))?;
        let listener = TcpListener::from_std(listener)?;
        let ((mut stream, direct, _pk, _kcp, _stream_type), (feedback, server)) = Client::start(
            &handler.get_id(),
            key,
            token,
            ConnType::PORT_FORWARD,
            handler.clone(),
        )
        .await?;
        handler.update_direct(Some(direct));
        let _keep_it = hc_connection(feedback, server, token).await;
        let mut pending_login = None;
        let mut challenged = false;
        loop {
            tokio::select! {
                result = timeout(std::time::Duration::from_millis(READ_TIMEOUT), stream.next()) => {
                    let bytes = result?.ok_or_else(|| anyhow!("Browser connection closed"))??;
                    handler.update_received(true);
                    match Message::parse_from_bytes(&bytes)?.union {
                        Some(message::Union::Hash(hash)) => {
                            challenged = true;
                            if !handler.handle_hash(&handler.password, hash, &mut stream).await {
                                return Ok(());
                            }
                            if let Some((os_user, os_password, password, remember)) = pending_login.take() {
                                handler.handle_login_from_ui(os_user, os_password, password, remember, &mut stream).await;
                            }
                        }
                        Some(message::Union::LoginResponse(response)) => match response.union {
                            Some(login_response::Union::Error(error)) => {
                                if !handler.handle_login_error(&error) {
                                    return Ok(());
                                }
                            }
                            Some(login_response::Union::PeerInfo(info)) => {
                                if info.platform != hbb_common::whoami::Platform::MacOS.to_string() || !info.features.as_ref().map(|f| f.port_forward_mux).unwrap_or(false) {
                                    bail!("Remote browser requires a compatible macOS host");
                                }
                                handler.handle_peer_info(info);
                                break;
                            }
                            _ => {}
                        },
                        Some(message::Union::TestDelay(delay)) => handler.handle_test_delay(delay, &mut stream).await,
                        _ => {}
                    }
                }
                data = receiver.recv() => match data {
                    Some(Data::Login((os_user, os_password, password, remember))) if challenged => {
                        handler.handle_login_from_ui(os_user, os_password, password, remember, &mut stream).await;
                    }
                    Some(Data::Login(login)) => pending_login = Some(login),
                    Some(Data::Message(message)) => stream.send(&message).await?,
                    Some(Data::Close) | None => return Ok(()),
                    _ => {}
                }
            }
        }
        let tunnel = Tunnel::new();
        let handle = tunnel.set_muxed(stream, handler.clone());
        (self.notify)("browser_ready");
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let (socket, _) = accepted?;
                    handle.open(&super::target(&self.token), 0, socket, Vec::new())?;
                }
                _ = tunnel.ended() => bail!("Browser connection closed"),
                data = receiver.recv() => match data {
                    Some(Data::Close) | None => return Ok(()),
                    _ => {}
                }
            }
        }
    }

    pub fn closed(&self) {
        (self.notify)("browser_closed");
    }
}

pub fn prepare(session: &crate::flutter::FlutterSession) -> ResultType<String> {
    if !session.is_port_forward() {
        bail!("Browser requires a dedicated tunneling session");
    }
    let ui = session.ui_handler.clone();
    let browser = std::sync::Arc::new(BrowserClient::prepare(move |name| {
        ui.push_event(name, &[] as &[(&str, String)], &[]);
    })?);
    let mut lc = session.lc.write().unwrap();
    if lc.browser.is_some() {
        bail!("Browser session already prepared");
    }
    let peer_identity = serde_json::to_string(&(
        lc.get_id(),
        &lc.other_server,
        hbb_common::config::Config::get_rendezvous_server(),
        hbb_common::config::Config::get_option("key"),
    ))?;
    let endpoint = serde_json::json!({
        "port": browser.port,
        "username": super::SOCKS_USERNAME,
        "password": browser.token,
        "peerIdentity": peer_identity,
    })
    .to_string();
    lc.port_forward = (super::target(&browser.token), 0);
    lc.port_forward_multiplex = true;
    lc.browser = Some(browser);
    Ok(endpoint)
}
