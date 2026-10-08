# Cutting a release

For the person who maintains this. Nothing here publishes anything; every step is local until the
last one, which is deliberately manual.

1. **Check everything.** Exactly what CI runs (and check the exit codes, not the last line of output):

   ```
   ruff check bin/surface-dial-hypr bin/surface-dial-rise-widget scripts/add-menu-entry.py tests
   ruff format --check bin/surface-dial-hypr bin/surface-dial-rise-widget scripts/add-menu-entry.py tests
   shellcheck install.sh uninstall.sh scripts/make-installer.sh scripts/installer-template.sh \
              bin/surface-dial-setup bin/surface-dial-restart bin/surface-dial-bar scripts/pair-dial.sh
   coverage run --include=bin/surface-dial-hypr tests/test_dial.py && coverage report --fail-under=75
   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
   omarchy-plugin-validate .
   ```

2. **Set the version** in `bin/surface-dial-hypr` (`__version__`), `manifest.json` and
   `plugin/dial.radial/manifest.json` (a test checks they agree), and add a dated section to
   `CHANGELOG.md`.
3. **Commit, then tag** (`git tag -a vX.Y.Z -m "..."`). The tag is what gets packaged.
4. **Build the single-file installer** from the tag:
   `scripts/make-installer.sh vX.Y.Z surface-dial-X.Y.Z-installer.sh`. It reads the version from the
   tagged source, so the file cannot disagree with what is inside it. Also build the plain archive:
   `git archive --prefix=surface-dial-X.Y.Z/ vX.Y.Z | gzip -n > surface-dial-X.Y.Z.tar.gz`.
5. **Prove it from a clean copy**: extract the archive somewhere else and run the tests there; run the
   installer with `--extract-only` and then in a scratch `HOME`.
6. **Put the Studio on the same build** before asking anyone else to run it.
7. **Publishing** (pushing the tag, a GitHub release, sending files to people) is a separate, deliberate
   decision, not part of this script.
