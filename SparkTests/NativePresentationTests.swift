import Testing

// AppKit windows share application focus and the field editor. MainActor only
// serializes synchronous work: async tests otherwise interleave while awaiting
// PTYs or layout, allowing another test's window to steal focus.
@Suite(.serialized)
struct NativePresentationTests {}
