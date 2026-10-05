// Language switcher.
//
// The menu is a plain <div hidden> rather than a <select>, because a select
// cannot show "فارسی" to someone who reads that script and "Persian" to someone
// who does not, and because a real menu can be styled and reached by keyboard.
//
// The chosen language is written into localStorage, so a reader who lands on the
// English root keeps their language on the next visit instead of being dropped
// back to English on every page.

(function () {
  'use strict';

  var KEY = 'vlip.lang';
  var root = document.querySelector('.langs');
  if (!root) return;

  var btn = root.querySelector('.langbtn');
  var menu = root.querySelector('.langmenu');
  if (!btn || !menu) return;

  function setOpen(open) {
    menu.hidden = !open;
    btn.setAttribute('aria-expanded', open ? 'true' : 'false');
  }

  function currentLang() {
    var code = document.documentElement.lang;
    return code === 'en' ? 'en' : code;
  }

  btn.addEventListener('click', function (e) {
    e.stopPropagation();
    setOpen(menu.hidden);
  });

  document.addEventListener('click', function (e) {
    if (!root.contains(e.target)) setOpen(false);
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') setOpen(false);
  });

  var links = menu.querySelectorAll('a');
  for (var i = 0; i < links.length; i++) {
    (function (link) {
      link.addEventListener('click', function () {
        // The language CHOSEN, not the one being read.
        //
        // It used to store currentLang(), which is the language of the page the
        // link was on. From Persian, choosing English therefore stored "fa", and
        // the English root -- which sees a saved non-English language -- sent the
        // reader straight back to Persian. Choosing English was impossible, and
        // reproduced on the live site, not just locally. Every language link
        // already carries its own code in hreflang, which is the thing to store.
        var chosen = link.getAttribute('hreflang');
        if (!chosen) return;
        try {
          if (chosen === 'en') {
            // English is the default: clear the choice rather than remember it.
            // Leaving "en" stored is harmless on its own, but it is one more
            // thing to reason about when the root check changes.
            window.localStorage.removeItem(KEY);
          } else {
            window.localStorage.setItem(KEY, chosen);
          }
        } catch (err) {
          /* private mode: remembering is a nicety, not a requirement */
        }
      });
    })(links[i]);
  }

  // A reader who chose a language should not have to choose it again, so send
  // them onward once, from the English root only. Doing it on every page would
  // fight the back button and make the URL lie about what is being read.
  //
  // The root test has to be the PROJECT root, not "any path ending in a slash":
  // /vlip/fa/ also ends in a slash. Getting that wrong is invisible until
  // something else changes, and it was only saved by the English check below.
  try {
    var saved = window.localStorage.getItem(KEY);
    var here = window.location.pathname;
    var atRoot = /\/vlip\/?$/.test(here) || here === '/';
    var englishPage = document.documentElement.lang === 'en';
    if (saved && saved !== 'en' && atRoot && englishPage) {
      window.location.replace(saved + '/');
    }
  } catch (err) {
    /* ignore */
  }
})();
