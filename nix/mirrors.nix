# Alternative hosts for source downloads, by URL prefix. nix/sources.nix hands the fetcher every
# spelling of a url (`urls`), tried in order; sources.toml keeps naming the canonical one.
{
  "https://ftp.gnu.org/gnu/" = [
    "https://ftpmirror.gnu.org/"
    "https://mirrors.kernel.org/gnu/"
  ];
  "https://ftpmirror.gnu.org/" = [
    "https://ftp.gnu.org/gnu/"
    "https://mirrors.kernel.org/gnu/"
  ];
  "https://download.savannah.gnu.org/releases/" = [
    "https://download-mirror.savannah.gnu.org/releases/"
  ];
  "https://download.savannah.nongnu.org/releases/" = [
    "https://download-mirror.savannah.gnu.org/releases/"
  ];
  "https://www.kernel.org/pub/" = [ "https://mirrors.edge.kernel.org/pub/" ];
  "https://cdn.kernel.org/pub/" = [ "https://mirrors.edge.kernel.org/pub/" ];
  "https://sourceware.org/pub/" = [ "https://mirrors.kernel.org/sourceware/" ];
}
