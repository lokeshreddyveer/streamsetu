// Drawings of the app, made of plain shapes. Real screenshots would show a provider's posters and channel logos, which this site does not use.
const tints = ["#6b4a2f", "#2f4b6b", "#4b2f6b", "#2f6b52", "#6b2f3f", "#5b5b2f", "#2f5a6b", "#6b3f2f"];

function Row({ title, count, offset = 0 }: { title: string; count: number; offset?: number }) {
  return (
    <div className="m-row">
      <span className="m-title">{title}</span>
      <div className="m-tiles">
        {Array.from({ length: count }, (_, i) => (
          <i key={i} style={{ background: `linear-gradient(160deg, ${tints[(i + offset) % tints.length]}, #12161f)` }} />
        ))}
      </div>
    </div>
  );
}

export function TvMockup() {
  return (
    <div className="m-tv" role="img" aria-label="A drawing of the StreamSetu home screen on a television">
      <div className="m-screen">
        <div className="m-rail">
          <i /><i className="on" /><i /><i /><i />
        </div>
        <div className="m-main">
          <div className="m-hero">
            <span className="m-name">Tonight</span>
            <span className="m-line" />
            <span className="m-line short" />
            <span className="m-btn">Play</span>
          </div>
          <Row title="Continue watching" count={6} />
          <Row title="Live now" count={6} offset={3} />
        </div>
      </div>
      <div className="m-stand" />
    </div>
  );
}

export function PhoneMockup() {
  return (
    <div className="m-phone" role="img" aria-label="A drawing of the StreamSetu home screen on a phone">
      <div className="m-pscreen">
        <div className="m-phero"><span className="m-name">Tonight</span><span className="m-btn">Play</span></div>
        <Row title="Continue watching" count={3} offset={2} />
        <Row title="Favourites" count={3} offset={5} />
        <div className="m-tabs"><i className="on" /><i /><i /><i /><i /></div>
      </div>
    </div>
  );
}
