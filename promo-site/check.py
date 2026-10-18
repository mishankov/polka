"""Check the static site, including links beneath a GitHub Pages project path."""
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent / "dist"
BASE_URL = "https://mishankov.github.io/polka/"


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.elements = []
        self.ids = []
        self.feed(path.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.elements.append((tag, attrs))
        if "id" in attrs:
            self.ids.append(attrs["id"])


def check_site():
    errors = []
    pages = {path: Page(path) for path in ROOT.rglob("*.html")}
    for path, page in pages.items():
        def check(condition, message):
            if not condition:
                errors.append(f"{path.relative_to(ROOT)}: {message}")

        check(not [key for key, count in Counter(page.ids).items() if count > 1], "duplicate IDs")
        language = "ru" if path.parent.name == "ru" else "en"
        html = next(attrs for tag, attrs in page.elements if tag == "html")
        check(html.get("lang") == language, "incorrect document language")
        canonical = next((attrs.get("href") for tag, attrs in page.elements
                          if tag == "link" and attrs.get("rel") == "canonical"), None)
        check(canonical == BASE_URL + ("ru/" if language == "ru" else ""), "incorrect canonical URL")
        alternates = {attrs.get("hreflang"): attrs.get("href") for tag, attrs in page.elements
                      if tag == "link" and attrs.get("rel") == "alternate"}
        check(alternates == {"en": BASE_URL, "ru": BASE_URL + "ru/", "x-default": BASE_URL},
              "missing or inconsistent language alternatives")
        switches = [attrs for tag, attrs in page.elements
                    if tag == "a" and "language-link" in attrs.get("class", "").split()]
        target_language = "en" if language == "ru" else "ru"
        check(len(switches) == 1 and switches[0].get("hreflang") == target_language
              and switches[0].get("lang") == target_language, "missing language switch")
        screenshots = [attrs for tag, attrs in page.elements
                       if tag == "img" and "feature-screenshot" in attrs.get("class", "").split()]
        check(len(screenshots) == 7, "expected seven capability screenshots")
        for tag, attrs in page.elements:
            if tag == "img":
                check("alt" in attrs and "width" in attrs and "height" in attrs,
                      f"image missing alternative text or dimensions: {attrs.get('src')}")
            for attribute in ("aria-labelledby", "aria-describedby", "aria-controls"):
                for identifier in attrs.get(attribute, "").split():
                    check(identifier in page.ids, f"unresolved {attribute}: {identifier}")
            for attribute in ("href", "src"):
                value = attrs.get(attribute)
                if value is None:
                    continue
                url = urlsplit(value)
                if url.scheme or url.netloc:
                    continue
                check(not url.path.startswith("/"), f"root-relative link breaks /polka/ hosting: {value}")
                target = (path.parent / unquote(url.path)).resolve() if url.path else path
                if target.is_dir():
                    target /= "index.html"
                check(target.is_relative_to(ROOT), f"link escapes published directory: {value}")
                check(target.is_file(), f"missing local target: {value}")
                if url.fragment and target in pages:
                    check(unquote(url.fragment) in pages[target].ids, f"missing anchor: {value}")
    en, ru = (pages[ROOT / name] for name in ("index.html", "ru/index.html"))
    if en.ids != ru.ids:
        errors.append("English and Russian page anchors differ")
    if not (ROOT / ".nojekyll").exists():
        errors.append("Missing .nojekyll for static deployment")
    if errors:
        raise SystemExit("\n".join(errors))
    print("English and Russian pages, language links, screenshots, anchors, and Pages paths passed.")


if __name__ == "__main__":
    check_site()
