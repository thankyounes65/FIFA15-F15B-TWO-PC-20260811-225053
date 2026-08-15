fn replace_once(source: &mut String, old: &str, new: &str, label: &str) {
    let count = source.matches(old).count();
    assert_eq!(count, 1, "{label}: expected one anchor, found {count}");
    *source = source.replacen(old, new, 1);
}

fn insert_before_once(source: &mut String, anchor: &str, insertion: &str, label: &str) {
    let count = source.matches(anchor).count();
    assert_eq!(count, 1, "{label}: expected one anchor, found {count}");
    let at = source.find(anchor).unwrap();
    source.insert_str(at, insertion);
}

fn main() {
    let mut matchmaking = r#"
const MATCHMAKING_SESSION_COMPLETION_CONTRACT: &str = "v14";
fn matchmaking_session_connection_validated_emitted() {}
fn matchmaking_postpeer_gsu_early_receiver_armed() {}
fn matchmaking_postpeer_gsu_replay_after_receiver_edge() {}
#[derive(Clone, Debug, PartialEq, Eq)]
enum PairingLobbyPeerNotification {
    GameSessionUpdated { game_id: u64 },
}
async fn pairing_lobby_send_peer_notification(
    stream: &mut TcpStream,
    trace: &Trace,
    config: &ExperimentConfig,
    notification: &PairingLobbyPeerNotification,
) -> bool {
    let sent = match notification {
        PairingLobbyPeerNotification::GameSessionUpdated { game_id } => {
            send_tdf_notification(
                stream,
                GAME_MANAGER_COMPONENT,
                GAME_MANAGER_NOTIFY_GAME_SESSION_UPDATED,
                &RealPairGameSessionUpdated { game_id: *game_id },
                "GameManager.NotifyGameSessionUpdated (pairing-lobby peer copy)",
                trace,
                config,
            )
            .await
        }
    };
    sent
}
fn early(game_id: u64) {
    let _ = PairingLobbyPeerNotification::GameSessionUpdated { game_id };
    let session_payload_policy = "preserve_observed_gid_only_empty_xnet";
}
fn replay(game_id: u64) {
    let notification = PairingLobbyPeerNotification::GameSessionUpdated {
        game_id,
    };
}
"#.to_owned();

    const SUPPORT: &str = r#"
const FIFA15_MM_V15_GSU_NPSI: &str = "fifa15_notify_game_session_updated_gid_npsi_empty_observed";
struct Fifa15PairGameSessionUpdated<'a> {
    game_id: u64,
    npsi: &'a str,
}

"#;
    insert_before_once(
        &mut matchmaking,
        "#[derive(Clone, Debug, PartialEq, Eq)]\nenum PairingLobbyPeerNotification {\n",
        SUPPORT,
        "support insertion",
    );

    replace_once(
        &mut matchmaking,
        r#"        PairingLobbyPeerNotification::GameSessionUpdated { game_id } => {
            send_tdf_notification(
                stream,
                GAME_MANAGER_COMPONENT,
                GAME_MANAGER_NOTIFY_GAME_SESSION_UPDATED,
                &RealPairGameSessionUpdated { game_id: *game_id },
                "GameManager.NotifyGameSessionUpdated (pairing-lobby peer copy)",
                trace,
                config,
            )
            .await
        }"#,
        r#"        PairingLobbyPeerNotification::GameSessionUpdated { game_id } => {
            send_tdf_notification(
                stream,
                GAME_MANAGER_COMPONENT,
                GAME_MANAGER_NOTIFY_GAME_SESSION_UPDATED,
                &Fifa15PairGameSessionUpdated {
                    game_id: *game_id,
                    npsi: "",
                },
                "GameManager.NotifyGameSessionUpdated (FIFA15 GID+NPSI v15 peer copy)",
                trace,
                config,
            )
            .await
        }"#,
        "common peer send arm",
    );

    replace_once(
        &mut matchmaking,
        "preserve_observed_gid_only_empty_xnet",
        "fifa15_v15_gid_plus_npsi_empty_observed_native_finalize",
        "policy marker",
    );

    assert!(matchmaking.contains("GameSessionUpdated { game_id: u64 }"));
    assert!(matchmaking.contains("PairingLobbyPeerNotification::GameSessionUpdated { game_id };"));
    assert!(matchmaking.contains("PairingLobbyPeerNotification::GameSessionUpdated {\n        game_id,\n    };"));
    assert!(matchmaking.contains("Fifa15PairGameSessionUpdated"));
    assert!(matchmaking.contains("npsi: \"\""));
    assert!(!matchmaking.contains("preserve_observed_gid_only_empty_xnet"));

    let start = matchmaking
        .find("PairingLobbyPeerNotification::GameSessionUpdated { game_id } =>")
        .unwrap();
    let tail = &matchmaking[start..];
    let end = tail.find("        }\n    };\n").unwrap();
    let send_arm = &tail[..end];
    assert!(!send_arm.contains("RealPairGameSessionUpdated"));
    assert!(!send_arm.contains("XNNC"));
    assert!(!send_arm.contains("XSES"));
    assert!(send_arm.contains("Fifa15PairGameSessionUpdated"));
    assert!(send_arm.contains("npsi: \"\""));

    println!("PASS: v15 common-send overlay transforms both queued and replay deliveries without changing v14 notification state shape");
}

struct TcpStream;
struct Trace;
struct ExperimentConfig;
struct RealPairGameSessionUpdated { game_id: u64 }
const GAME_MANAGER_COMPONENT: u16 = 4;
const GAME_MANAGER_NOTIFY_GAME_SESSION_UPDATED: u16 = 0x73;
async fn send_tdf_notification<T>(_: &mut TcpStream, _: u16, _: u16, _: &T, _: &str, _: &Trace, _: &ExperimentConfig) -> bool { true }
