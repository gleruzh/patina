// NOTICE: This file is part of rustdesk-server (AGPL-3.0) and was modified
// by Patina contributors in 2026. See PATCHES.md for the list of changes.

mod rendezvous_server;
pub use rendezvous_server::*;
pub mod common;
mod database;
mod peer;
mod version;
mod ws_peers;
