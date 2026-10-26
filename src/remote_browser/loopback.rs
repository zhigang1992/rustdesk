use hbb_common::{
    anyhow::bail,
    tokio::{
        self,
        io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
        net::TcpStream,
    },
    ResultType,
};

const HOSTS: [(&str, &str); 3] = [
    ("localhost.rustdesk.localhost", "localhost"),
    ("ipv4.rustdesk.localhost", "127.0.0.1"),
    ("ipv6.rustdesk.localhost", "::1"),
];

pub fn target(host: &str) -> ResultType<Option<&'static str>> {
    let host = host.trim_end_matches('.');
    for (alias, destination) in HOSTS {
        if host.eq_ignore_ascii_case(alias) {
            return Ok(Some(destination));
        }
    }
    if host.to_ascii_lowercase().ends_with(".rustdesk.localhost") {
        bail!("Unknown remote browser loopback alias");
    }
    Ok(None)
}

fn map_url(value: &str, remote: bool) -> String {
    let Ok(mut url) = url::Url::parse(value) else {
        return value.to_owned();
    };
    if !matches!(url.scheme(), "http" | "https" | "ws" | "wss") {
        return value.to_owned();
    }
    let Some(host) = url.host_str() else {
        return value.to_owned();
    };
    for (alias, destination) in HOSTS {
        let destination = if destination == "::1" {
            "[::1]"
        } else {
            destination
        };
        let (from, to) = if remote {
            (alias, destination)
        } else {
            (destination, alias)
        };
        if host.eq_ignore_ascii_case(from) {
            if url.set_host(Some(to)).is_ok() {
                return url.into();
            }
            break;
        }
    }
    value.to_owned()
}

fn header(bytes: Vec<u8>, remote: bool) -> ResultType<Vec<u8>> {
    let text = String::from_utf8(bytes)?;
    let mut lines = text.split("\r\n");
    let first = lines.next().unwrap_or_default();
    let upgrade = if remote {
        text.lines().any(|line| {
            line.split_once(':')
                .map(|(name, value)| {
                    name.eq_ignore_ascii_case("upgrade")
                        && value.trim().eq_ignore_ascii_case("websocket")
                })
                .unwrap_or(false)
        })
    } else {
        first.split_whitespace().nth(1) == Some("101")
    };
    let mut output = format!("{}\r\n", first);
    for line in lines.filter(|line| !line.is_empty()) {
        let Some((name, value)) = line.split_once(':') else {
            bail!("Invalid loopback HTTP header")
        };
        let value = value.trim();
        if name.eq_ignore_ascii_case("connection") && !upgrade {
            continue;
        }
        let mapped = if remote && name.eq_ignore_ascii_case("host") {
            map_url(&format!("http://{}/", value), true)
                .trim_start_matches("http://")
                .trim_end_matches('/')
                .to_owned()
        } else if [
            "origin",
            "referer",
            "sec-websocket-origin",
            "location",
            "content-location",
            "access-control-allow-origin",
        ]
        .iter()
        .any(|key| name.eq_ignore_ascii_case(key))
        {
            let mapped = map_url(value, remote);
            if [
                "origin",
                "sec-websocket-origin",
                "access-control-allow-origin",
            ]
            .iter()
            .any(|key| name.eq_ignore_ascii_case(key))
            {
                mapped.trim_end_matches('/').to_owned()
            } else {
                mapped
            }
        } else if !remote && name.eq_ignore_ascii_case("set-cookie") {
            value
                .split(';')
                .map(|part| {
                    if let Some((key, domain)) = part.trim().split_once('=') {
                        if key.eq_ignore_ascii_case("domain") {
                            for (alias, destination) in HOSTS {
                                if domain
                                    .trim_start_matches('.')
                                    .eq_ignore_ascii_case(destination)
                                {
                                    return format!(" Domain={}", alias);
                                }
                            }
                        }
                    }
                    part.to_owned()
                })
                .collect::<Vec<_>>()
                .join(";")
        } else if !remote && name.eq_ignore_ascii_case("content-security-policy") {
            value
                .split(' ')
                .map(|part| map_url(part, false))
                .collect::<Vec<_>>()
                .join(" ")
        } else {
            value.to_owned()
        };
        output.push_str(&format!("{}: {}\r\n", name, mapped));
    }
    // A separate connection per HTTP exchange keeps bodies opaque, including chunked uploads and SSE.
    if !upgrade {
        output.push_str("Connection: close\r\n");
    }
    output.push_str("\r\n");
    Ok(output.into_bytes())
}

async fn read_header<R: tokio::io::AsyncBufRead + Unpin>(reader: &mut R) -> ResultType<Vec<u8>> {
    let mut header = Vec::new();
    loop {
        let bytes = reader.fill_buf().await?;
        if bytes.is_empty() {
            bail!("Loopback HTTP connection closed before headers");
        }
        let length = bytes
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|i| i + 1)
            .unwrap_or(bytes.len());
        if header.len() + length > 64 * 1024 {
            bail!("Loopback HTTP headers exceed 64 KiB");
        }
        header.extend_from_slice(&bytes[..length]);
        reader.consume(length);
        if header.ends_with(b"\r\n\r\n") {
            return Ok(header);
        }
    }
}

pub async fn relay(socket: TcpStream, remote: TcpStream) -> ResultType<()> {
    let mut browser = BufReader::new(socket);
    let mut server = BufReader::new(remote);
    // TLS remains end-to-end; synthetic names still require a matching server certificate.
    if browser.fill_buf().await?.first() == Some(&22) {
        tokio::io::copy_bidirectional(&mut browser, &mut server).await?;
        return Ok(());
    }
    let request = read_header(&mut browser).await?;
    server.write_all(&header(request, true)?).await?;
    let (mut browser_read, mut browser_write) = tokio::io::split(browser);
    let (server_read, mut server_write) = tokio::io::split(server);
    let mut server_read = BufReader::new(server_read);
    let upload = async {
        tokio::io::copy(&mut browser_read, &mut server_write).await?;
        server_write.shutdown().await?;
        std::future::pending::<ResultType<()>>().await
    };
    let download = async {
        loop {
            let response = read_header(&mut server_read).await?;
            let status = response
                .split(|byte| *byte == b' ')
                .nth(1)
                .unwrap_or_default();
            let interim = status.len() == 3 && status[0] == b'1' && status != b"101";
            if interim {
                browser_write.write_all(&response).await?;
            } else {
                browser_write.write_all(&header(response, false)?).await?;
                break;
            }
        }
        tokio::io::copy(&mut server_read, &mut browser_write).await?;
        browser_write.shutdown().await?;
        Ok(())
    };
    tokio::select! { result = upload => result, result = download => result }
}
