# Hosting your own installers and files

Most apps come from winget or straight from the vendor, so they are always the latest version and need no hosting. This page is for the rest: installers that aren't on winget or a vendor link, settings files, templates and so on.

They go in the **files** release of this repo: <https://github.com/Vector-Contour/Windows-Setup/releases/tag/files>. The script downloads them at run time, so nothing is bundled into the script and replacing an upload is all it takes to ship a new version.

**This repo is public, so anyone can download anything in that release.** Only put files there that you'd be happy for a stranger to have.

## Public or private?

Ask: "Would I be fine with a competitor or a stranger downloading this, or reading its name?"

- **Yes: public.** Free tools, generic settings files, wallpapers, folder layouts with no customer names. Put them in the files release.
- **No, or not sure: private.** Your own software, customer or project names, internal templates, server names or IP addresses, licence keys, passwords, and paid software you may install but not redistribute. Don't put these anywhere in this repo, not even their names in a preset. For now, copy them onto each PC by hand after the setup run (later they can come from the wiki, see below).

## Adding or replacing a file

1. Open [the files release](https://github.com/Vector-Contour/Windows-Setup/releases/tag/files) and click the pencil (**Edit**).
2. Drag the file into "Attach binaries". To replace a file, first click the bin next to the old one, then upload the new one **with the same file name**.
3. Leave **Set as a pre-release** ticked (it keeps this release out of "latest"), and click **Update release**.
4. Refer to it in a preset as `files:<exact file name>`. An installer:

```json
{ "name": "Acme Viewer", "url": "files:AcmeViewerSetup.exe", "args": "/S", "detect": "Acme Viewer*" }
```

A file copied into place:

```json
{ "source": "files:settings.json", "destination": "%APPDATA%\\AcmeViewer\\settings.json" }
```

File names are case-sensitive; spaces are fine. A single file can be up to 2 GB. An existing destination file is kept unless the entry has `"overwrite": true`.

The release is created automatically the first time the repo's build runs on `main`, so it appears once the first pull request is merged.

## Later: private files from a login-protected site

The script already understands `private:<file name>`, used just like `files:`. Until a private download location is set, those entries aren't downloaded: the run lists each one as a yellow **[by hand]** step so you know what to copy yourself.

When the wiki (or anywhere else behind a login) can serve the files, set `$PrivateFilesUrl` near the top of `winsetup.ps1` to its base address and add the sign-in step next to it. Presets that use `private:` names would live behind that login too, so the names never appear in this repo.
