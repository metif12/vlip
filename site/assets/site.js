// Language switcher.
//
// The menu is a plain <div hidden> rather than a <select>, because a select
// cannot show "فارسی" to someone who reads that script and "Persian" to someone
// who does not, and because a real menu can be styled and reached by keyboard.
//
// The current language is written into localStorage as well, so a reader who
// lands on the English root and switches once keeps their language on the next
// visit instead of being dropped back to English on every page.

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
    links[i].addEventListener('click', function () {
      try {
        window.localStorage.setItem(KEY, currentLang());
      } catch (err) {
        /* private mode: remembering is a nicety, not a requirement */
      }
    });
  }

  // A reader who chose a language should not have to choose it again, so send
  // them onward once, from the English root only. Doing it on every page would
  // fight the back button and make the URL lie about what is being read.
  try {
    var saved = window.localStorage.getItem(KEY);
    var here = window.location.pathname;
    var atRoot = /\/vlip\/?$|\/$/.test(here);
    var englishPage = document.documentElement.lang === 'en';
    if (saved && saved !== 'en' && atRoot && englishPage) {
      window.location.replace(saved + '/');
    }
  } catch (err) {
    /* ignore */
  }
})();
