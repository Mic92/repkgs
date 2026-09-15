# cpython.project's devEnv: bin/python3 that imports the checkout named by REPKGS_PROJECT
{ pkgs }: (pkgs.cpython.project { src = ./src; }).devEnv
