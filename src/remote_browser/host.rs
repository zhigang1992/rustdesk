use super::Connection;

impl Connection {
    pub(super) async fn connect_remote_browser(&mut self, multiplex: bool, token: String) -> bool {
        if !multiplex {
            self.send_login_error("Remote browser requires multiplexed tunneling")
                .await;
            return false;
        }
        #[cfg(target_os = "macos")]
        {
            let Some(tx) = self.inner.tx.clone() else {
                return false;
            };
            match crate::server::port_forward_mux::PortForwardMux::browser(
                tx,
                self.port_forward_address.clone(),
                token,
            )
            .await
            {
                Ok(mux) => {
                    crate::port_forward_mux::cap_packet_size(&mut self.stream);
                    self.port_forward_mux = Some(mux);
                    true
                }
                Err(error) => {
                    hbb_common::log::warn!("Cannot start browser proxy: {}", error);
                    self.send_login_error("Cannot start remote browser proxy")
                        .await;
                    false
                }
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = token;
            self.send_login_error("Remote browser requires a macOS host")
                .await;
            false
        }
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use base::message_proto::{message, port_forward_channel, PortForwardChannel, PortForwardOpen};
    use hbb_common::tokio::{self, sync::mpsc};

    #[tokio::test]
    async fn browser_mux_keeps_permission_and_exact_login_target_checks() {
        let host = crate::remote_browser::target("5981d37d-1094-4217-9e43-23e51365304c");
        let (tx, mut rx) = mpsc::unbounded_channel();
        let mut mux = crate::server::port_forward_mux::PortForwardMux::browser(
            tx,
            format!("{}:0", host),
            "5981d37d-1094-4217-9e43-23e51365304c".to_owned(),
        )
        .await
        .unwrap();
        for (id, requested_host, permitted, accepted) in [
            (1, "localhost", true, false),
            (2, host.as_str(), false, false),
            (3, host.as_str(), true, true),
        ] {
            let mut frame = PortForwardChannel::new();
            frame.set_open(PortForwardOpen {
                channel_id: id,
                host: requested_host.to_owned(),
                port: 0,
                ..Default::default()
            });
            mux.handle(frame, || permitted);
            let (_, response) = rx.recv().await.unwrap();
            let Some(message::Union::PortForwardChannel(channel)) = &response.union else {
                panic!("expected channel response")
            };
            let Some(port_forward_channel::Union::Opened(opened)) = &channel.union else {
                panic!("expected opened response")
            };
            assert_eq!((opened.channel_id, opened.success), (id, accepted));
        }
        mux.close_all();
    }
}
