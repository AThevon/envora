{ lib
, stdenvNoCC
, makeWrapper
, age
, fzf
, gum
, gh
, git
, jq
, coreutils
, findutils
, gnused
, gnugrep
, gawk
, diffutils
}:

stdenvNoCC.mkDerivation {
  pname = "envora";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 ev.sh $out/bin/ev
    mkdir -p $out/lib/envora
    cp -r lib/. $out/lib/envora/
    runHook postInstall
  '';

  postFixup = ''
    wrapProgram $out/bin/ev \
      --set ENVORA_LIB "$out/lib/envora" \
      --prefix PATH : ${lib.makeBinPath [ age fzf gum gh git jq coreutils findutils gnused gnugrep gawk diffutils ]}
  '';

  meta = with lib; {
    description = "Encrypted vault for the untracked .env files of all your projects (age + git), with Vercel and Cloudflare support";
    homepage = "https://github.com/AThevon/envora";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "ev";
  };
}
