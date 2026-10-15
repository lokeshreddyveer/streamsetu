export function PrivacyMap() {
  return (
    <div className="pmap">
      <div className="pnode">
        <strong>Your device</strong>
        <small>Playlists, logins, favourites and history stay here</small>
      </div>
      <div className="plink"><span>talks straight to</span></div>
      <div className="pnode">
        <strong>Your provider</strong>
        <small>The server you give it</small>
      </div>
      <div className="pnode ghost">
        <strong>A StreamSetu server</strong>
        <small>There isn't one. No account, no analytics, no ads.</small>
      </div>
    </div>
  );
}
