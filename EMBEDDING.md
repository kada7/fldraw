# Embeddable board API

The maintained fork adds `package:fldraw/board.dart`. It shares fldraw's Flutter drawing purpose and perfect-freehand stroke geometry, but replaces asynchronous, separate node/drawing mutation paths with one immutable document and synchronous command history. The classic entry point remains available for existing users; the embedded board does not install a nested app or Shadcn theme.

`BoardController` owns `BoardDocument`, tools, selection, undo/redo and gesture transactions. `BoardView` renders standard objects and calls a host `nodeBuilder` for custom content. Reserve the top 48 world pixels and the outer 10-pixel border of a custom node for moving it; its body can contain ordinary Flutter scroll/links. In select mode, empty space pans. Drawing tools own one pointer; two pointers always transform the viewport and cancel an uncommitted single-pointer gesture.

`BoardInspector` inherits the host's Material theme and edits common selected properties. It includes fill/stroke, dash style, text formatting and custom hex colors. Selection actions are clamped to the viewport. Erasing deletes complete pencil strokes. Image payloads are self-contained base64 originals; supported raster codecs and local SVG can be displayed, saved and exported offline.

Serialize with `controller.document.toJson()` and load with `BoardDocument.fromJson`. Schema 1 validates object identities and geometry; unsupported schemas fail rather than being rewritten. Custom data must be JSON, is immutable, and belongs to the host. Stable application references, account files, authentication and persistence are deliberately absent from the engine. The host should wrap the document with its own version/engine identity and preserve unsupported originals.

`BoardViewState.capturePng(prepare: ...)` renders the entire content bounds, including offscreen custom widgets, into an isolated fitted scene. The host may preload asynchronous custom resources in `prepare`; export builders receive `exporting=true` and must restore the current reading clip without sharing one ScrollController between live/export trees. Selection chrome is excluded. Output is capped at 8192 pixels per dimension and 24 million pixels, scaling down rather than cropping large documents.

For dirty tracking, `fingerprint` is cached between document changes. During pointer interaction the controller exposes `interacting`, so a host need not serialize large embedded image payloads per pointer sample. Host reading offsets must stay outside the document/history. Saving/exporting is controlled by the host; use `readOnly` while awaiting a snapshot/commit.

Run the independent example with `flutter run -t lib/board_example.dart` from `example/`. Focused checks: `flutter test test/board_test.dart` and `dart analyze lib/src/board lib/board.dart test/board_test.dart`.
