/// Presentation lifecycle, matching upstream onPostRender phases.
/// Mount means the first installed presentation, independent of window visibility.
public enum PostRenderPhase: String, Sendable { case mount, update, unmount }
