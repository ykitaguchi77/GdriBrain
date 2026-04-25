import SwiftUI
@preconcurrency import WebKit

struct GraphView: View {
    @State private var payload: GraphPayload?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if let payload {
                    GraphWebView(payload: payload)
                        .ignoresSafeArea()
                } else if let error {
                    ContentUnavailableView(
                        "Graph unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Graph")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        payload = await GraphService.shared.snapshot()
        if (payload?.nodes.isEmpty ?? true) {
            error = "No notes yet."
        } else {
            error = nil
        }
    }
}

private struct GraphWebView: UIViewRepresentable {
    let payload: GraphPayload

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.isOpaque = false
        web.scrollView.bounces = false
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let encoder = JSONEncoder()
        let nodesJSON = (try? encoder.encode(payload.nodes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let edgesJSON = (try? encoder.encode(payload.edges)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body, #cy { height: 100%; margin: 0; }
            body { background: #111; color: #eee; font-family: -apple-system; }
          </style>
          <script src="https://unpkg.com/cytoscape@3.28.1/dist/cytoscape.min.js"></script>
        </head>
        <body>
          <div id="cy"></div>
          <script>
            const nodes = \(nodesJSON);
            const edges = \(edgesJSON);
            cytoscape({
              container: document.getElementById('cy'),
              elements: [
                ...nodes.map(n => ({ data: { id: n.id, label: n.title, source: n.source }})),
                ...edges.map(e => ({ data: { id: e.source + '->' + e.target + '/' + e.kind,
                                              source: e.source, target: e.target,
                                              kind: e.kind, weight: e.weight }}))
              ],
              style: [
                { selector: 'node', style: {
                  'background-color': '#4fa3ff',
                  'label': 'data(label)',
                  'color': '#eee',
                  'font-size': 10,
                  'text-wrap': 'wrap',
                  'text-max-width': 80,
                }},
                { selector: 'node[source="link"]', style: { 'background-color': '#f5a623' }},
                { selector: 'node[source="screenshot"]', style: { 'background-color': '#7ed321' }},
                { selector: 'edge', style: {
                  'width': 'mapData(weight, 0, 1, 1, 4)',
                  'line-color': '#555',
                  'curve-style': 'bezier',
                }},
                { selector: 'edge[kind="related"]', style: { 'line-style': 'dashed' }}
              ],
              layout: { name: 'cose', animate: false }
            });
          </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://local.gdribrain/"))
    }
}
