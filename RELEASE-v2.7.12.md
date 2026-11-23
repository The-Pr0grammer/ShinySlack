# ShinySlack v2.7.12

- Dashboard themes: Shiny, Retro, Arcade and Ghost Type, synchronized to the HTML deck.
- Fixed theme persistence on Windows by supplying a valid backup path to File.Replace.
- Dashboard Open Alert Deck now uses the existing HTML host's restore request instead of triggering guarded ownership promotion merely to show the window.
- Preserved native fallback, router, sound guard and existing ownership validation.

Release caveat: V10.4 installed-runtime promotion integrity manifests require separate reconciliation and a fresh-install ownership validation. A restored visible window alone does not prove HTML notification ownership.