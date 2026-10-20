//! What StreamSetu for Windows needs that is not the window itself: the stream proxy and the safe place for logins. Kept apart from the app so it builds and is tested on any computer.
pub mod proxy;
pub mod rewrite;
pub mod secrets;
