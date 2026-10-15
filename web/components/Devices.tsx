import { Art } from "./Art";



// The player, with its options pointed out. Positions are in percent of the picture.
export function PlayerScreen() {
  return (
    <div className="player" role="img" aria-label="A drawing of the StreamSetu player with its main controls labelled">
      <Art seed={5} className="player-art" />
      <div className="player-top">
        <span className="player-title">Episode 4 · The Crossing</span>
        <span className="player-icons"><i className="search" /><i /><i /></span>
      </div>
      <div className="stats">
        <b>Stats</b>
        <span>Player <em>ExoPlayer</em></span>
        <span>Video <em>1920×1080 · h264</em></span>
        <span>Bitrate <em>6.1 Mbps</em></span>
        <span>Buffer <em>24 s</em></span>
        <span>Dropped <em>0</em></span>
      </div>
      <div className="skip">Skip Intro</div>
      <div className="player-mid"><i /></div>
      <div className="player-bottom">
        <div className="seek">
          <span className="seek-played" />
          <span className="seek-dot" />
          <i style={{ left: "18%" }} /><i style={{ left: "37%" }} /><i style={{ left: "61%" }} /><i style={{ left: "82%" }} />
        </div>
        <div className="player-row">
          <span>0:24:10</span>
          <span className="chips"><i>Audio</i><i>Subtitles</i><i>1×</i><i>Picture</i><i>More</i></span>
          <span>-0:36:50</span>
        </div>
      </div>
      <span className="note n1"><b>Search</b>the whole catalog without leaving</span>
      <span className="note n2"><b>Stats overlay</b>decoder, bitrate, buffer</span>
      <span className="note n3"><b>Skip Intro</b>learned from your first skip</span>
      <span className="note n4"><b>Chapters</b>and go to any time</span>
      <span className="note n5"><b>Remembered</b>audio, subtitles and speed come back</span>
    </div>
  );
}
