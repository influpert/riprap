/* riprap.dev — behaviour.
 *
 * Everything here is progressive: with JavaScript disabled the site still renders, still
 * navigates, and still honours the operating system's colour scheme. Nothing below reveals
 * content — content that is hidden until a script runs is content that can fail to appear.
 */
(function () {
  'use strict';

  var root = document.documentElement;

  /* ---- Theme -------------------------------------------------------------
   * The inline script in <head> already decided the theme before first paint. This reads
   * that decision rather than deriving it again, so the button can never disagree with the
   * page it is sitting on. */
  var toggle = document.getElementById('theme-toggle');

  function applyTheme(theme) {
    root.setAttribute('data-theme', theme);
    if (!toggle) return;
    var dark = theme === 'dark';
    toggle.setAttribute('aria-pressed', dark ? 'true' : 'false');
    toggle.setAttribute('aria-label', dark ? 'Switch to light mode' : 'Switch to dark mode');
  }

  applyTheme(root.getAttribute('data-theme') || 'light');

  if (toggle) {
    toggle.addEventListener('click', function () {
      var next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      applyTheme(next);
      try { localStorage.setItem('theme', next); } catch (e) { /* private mode: honour the click, forget the choice */ }
    });
  }

  /* ---- Navbar state ----------------------------------------------------- */
  var navbar = document.getElementById('navbar');
  var menu = document.getElementById('nav-menu');
  var hamburger = document.getElementById('hamburger');

  if (navbar) {
    var onScroll = function () {
      navbar.classList.toggle('scrolled', window.scrollY > 8);
    };
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  if (hamburger && menu) {
    var setMenu = function (open) {
      menu.classList.toggle('open', open);
      hamburger.setAttribute('aria-expanded', open ? 'true' : 'false');
      hamburger.setAttribute('aria-label', open ? 'Hide navigation' : 'Show navigation');
    };
    hamburger.addEventListener('click', function () {
      setMenu(hamburger.getAttribute('aria-expanded') !== 'true');
    });
    /* Close on navigation and on Escape. Without the first, following a link on a phone
     * leaves the panel covering the page you just asked for. */
    menu.addEventListener('click', function (e) {
      if (e.target.closest('a')) setMenu(false);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && hamburger.getAttribute('aria-expanded') === 'true') {
        setMenu(false);
        hamburger.focus();
      }
    });
  }

  /* ---- Table rows become labelled cards on narrow screens ---------------
   * screen.css turns each row into a card below 760px, with each cell's column header
   * shown as a caption above its value — kramdown has no way to attach that label from
   * plain pipe-table syntax, so it's copied from <thead> onto a data-label attribute here.
   * Harmless above 760px: the CSS that reads it only applies under that breakpoint. */
  var tables = document.querySelectorAll('.prose > table');
  Array.prototype.forEach.call(tables, function (table) {
    var headers = Array.prototype.map.call(table.querySelectorAll('thead th'), function (th) {
      return th.textContent.trim();
    });
    var rows = table.querySelectorAll('tbody tr');
    Array.prototype.forEach.call(rows, function (row) {
      Array.prototype.forEach.call(row.children, function (cell, i) {
        if (headers[i]) cell.setAttribute('data-label', headers[i]);
      });
    });
  });

  /* ---- Linkable headings -----------------------------------------------
   * kramdown gives every heading an id; nothing surfaces them, so a reader cannot link to
   * a section they want to quote. */
  var headings = document.querySelectorAll('.prose h2[id], .prose h3[id]');
  Array.prototype.forEach.call(headings, function (h) {
    var a = document.createElement('a');
    a.className = 'heading-anchor';
    a.href = '#' + h.id;
    a.setAttribute('aria-label', 'Link to this section');
    a.textContent = '#';
    h.appendChild(a);
  });
}());
