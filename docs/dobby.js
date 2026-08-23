// The guide's one script. Three things, none of them needed to read the page:
// a copy button on every command, the "on this page" list following the
// scroll, and the proof flaps landing on their word the first time they are
// seen. Everything here degrades to a plain page.

(function () {
  "use strict";

  // -- copy --------------------------------------------------------------
  // Every <pre> gets a quiet brass `copy`. The label says what happened and
  // then goes back to being an offer, the way an undo line does.
  if (navigator.clipboard) {
    document.querySelectorAll("pre").forEach(function (pre) {
      var button = document.createElement("button");
      button.type = "button";
      button.className = "copy";
      button.textContent = "copy";
      button.setAttribute("aria-label", "Copy this to the clipboard");
      button.addEventListener("click", function () {
        var code = pre.querySelector("code") || pre;
        navigator.clipboard.writeText(code.innerText.replace(/\n$/, "")).then(
          function () {
            button.textContent = "copied";
            button.setAttribute("data-done", "");
            setTimeout(function () {
              button.textContent = "copy";
              button.removeAttribute("data-done");
            }, 1600);
          },
          function () {
            button.textContent = "could not copy";
          }
        );
      });
      pre.appendChild(button);
    });
  }

  // -- on this page --------------------------------------------------------
  // The list is built from the page's own h2s, so a section added to the
  // prose appears here without a second edit.
  var onpage = document.querySelector(".onpage");
  var headings = Array.prototype.slice.call(document.querySelectorAll("article h2[id]"));

  if (onpage && headings.length) {
    var list = document.createElement("ol");
    var links = headings.map(function (h) {
      var li = document.createElement("li");
      var a = document.createElement("a");
      a.href = "#" + h.id;
      a.textContent = h.textContent;
      li.appendChild(a);
      list.appendChild(li);
      return a;
    });
    onpage.appendChild(list);

    if ("IntersectionObserver" in window) {
      var current = null;
      var mark = function (index) {
        if (index === current) return;
        current = index;
        links.forEach(function (a, i) {
          if (i === index) a.setAttribute("aria-current", "true");
          else a.removeAttribute("aria-current");
        });
      };
      var pick = function () {
        var line = 120;
        var index = 0;
        for (var i = 0; i < headings.length; i++) {
          if (headings[i].getBoundingClientRect().top <= line) index = i;
        }
        mark(index);
      };
      var observer = new IntersectionObserver(pick, { rootMargin: "-100px 0px -70% 0px" });
      headings.forEach(function (h) {
        observer.observe(h);
      });
      window.addEventListener("scroll", pick, { passive: true });
      pick();
    }
  } else if (onpage) {
    onpage.remove();
  }

  // -- the flap lands ------------------------------------------------------
  // A split-flap finds its word once. The word is on the card from the
  // start — a flap nobody has scrolled to is still a flap — and it turns over
  // the first time the card is in view; after that it is just a word.
  var proofs = document.querySelectorAll(".proof");
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  if (proofs.length && !reduced && "IntersectionObserver" in window) {
    var landing = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          entry.target.setAttribute("data-landed", "");
          landing.unobserve(entry.target);
        });
      },
      { threshold: 0.35 }
    );
    proofs.forEach(function (p) {
      landing.observe(p);
    });
  }
})();
