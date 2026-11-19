"""Read a built bearings detail page or board as a browser would and print what
it shows, so tests assert rendered behavior rather than template source.

Usage:
  python3 -I bearings-detail-harness.py detail <bearings-detail.html>
  python3 -I bearings-detail-harness.py links <bearings-board.html>

detail prints {"scripts": N, "sections": {"<id>": {"title", "empty", "more",
  "items": [{"anchor", "title", "badge", "fields": {"<key>": {"label", "text",
  "links": [{"href", "text"}]}}}]}}} with every text decoded from its entities.
links prints [{"id", "href", "target", "rel", "context"}] for every anchor,
  where context is "nav" inside the board header or the eyebrow text of the
  section header the anchor sits in.
"""
import json
import sys
from html.parser import HTMLParser

VOID = {"meta", "link", "br", "img", "input", "hr", "source", "area", "base", "col", "wbr"}


class Node:
    def __init__(self, tag, attrs, parent):
        self.tag = tag
        self.attrs = dict(attrs)
        self.parent = parent
        self.children = []

    def classes(self):
        return (self.attrs.get("class") or "").split()

    def text(self):
        out = []
        for c in self.children:
            out.append(c if isinstance(c, str) else c.text())
        return "".join(out)

    def walk(self):
        for c in self.children:
            if isinstance(c, Node):
                yield c
                yield from c.walk()

    def find(self, pred):
        return [n for n in self.walk() if pred(n)]


class Tree(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#root", [], None)
        self.cur = self.root

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs, self.cur)
        self.cur.children.append(node)
        if tag not in VOID:
            self.cur = node

    def handle_endtag(self, tag):
        n = self.cur
        while n is not None and n.tag != tag:
            n = n.parent
        if n is not None and n.parent is not None:
            self.cur = n.parent

    def handle_data(self, data):
        self.cur.children.append(data)


def parse(path):
    tree = Tree()
    with open(path, encoding="utf-8") as fh:
        tree.feed(fh.read())
    tree.close()
    return tree.root


def squash(s):
    return " ".join(s.split())


def detail(root):
    sections = {}
    for sec in root.find(lambda n: n.tag == "section"):
        title = next((squash(h.text()) for h in sec.find(lambda n: n.tag == "h2")), "")
        items = []
        for art in sec.find(lambda n: n.tag == "article"):
            fields = {}
            for f in art.find(lambda n: "dt-field" in n.classes()):
                dt = next((squash(x.text()) for x in f.find(lambda n: n.tag == "dt")), "")
                dd = next((x for x in f.find(lambda n: n.tag == "dd")), None)
                fields[f.attrs.get("data-field", "")] = {
                    "label": dt,
                    "text": squash(dd.text()) if dd else "",
                    "links": [{"href": a.attrs.get("href"), "text": squash(a.text())}
                              for a in (dd.find(lambda n: n.tag == "a") if dd else [])],
                }
            items.append({
                "anchor": art.attrs.get("id"),
                "title": next((squash(h.text()) for h in art.find(lambda n: n.tag == "h3")), ""),
                "badge": next((squash(b.text()) for b in art.find(lambda n: "fm-badge" in n.classes())), ""),
                "fields": fields,
            })
        sections[sec.attrs.get("id", "")] = {
            "title": title,
            "empty": next((squash(p.text()) for p in sec.find(lambda n: "dt-empty" in n.classes())), None),
            "more": [squash(p.text()) for p in sec.find(lambda n: "dt-more" in n.classes())],
            "items": items,
        }
    return {"scripts": len(root.find(lambda n: n.tag == "script")), "sections": sections}


def context_of(node):
    n = node.parent
    while n is not None:
        if "bb-nav" in n.classes():
            return "nav"
        if "bb-section__head" in n.classes():
            eyebrow = next((e for e in n.find(lambda x: "fm-sign--eyebrow" in x.classes())), None)
            return squash(eyebrow.text()) if eyebrow else ""
        n = n.parent
    return ""


def links(root):
    return [{"id": a.attrs.get("id"), "href": a.attrs.get("href"), "target": a.attrs.get("target"),
             "rel": a.attrs.get("rel"), "lavish_action": "data-lavish-action" in a.attrs,
             "context": context_of(a)}
            for a in root.find(lambda n: n.tag == "a")]


def main():
    mode, path = sys.argv[1], sys.argv[2]
    root = parse(path)
    print(json.dumps(detail(root) if mode == "detail" else links(root)))


main()
