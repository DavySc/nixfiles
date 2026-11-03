;;; kitty-nix.el --- Nix  -*- lexical-binding: t; -*-

;;; Commentary:

;; nix-ts-mode, nil as the language server, nixfmt on save.

;;; Code:

(require 'kitty-lib)

(add-to-list 'auto-mode-alist '("\\.nix\\'" . nix-ts-mode))
(kitty-add-hook 'nix-ts-mode-hook (lambda () (kitty-eglot-ensure-for "nil")))

(kitty-local-leader 'nix-ts-mode
  "f" '("format" . kitty-format)
  "r" '("rebuild (compile)" . kitty-nix-rebuild))

(defun kitty-nix-rebuild ()
  "Rebuild the NixOS configuration the flake in this project defines."
  (interactive)
  (let ((default-directory (kitty-project-root)))
    (compile "sudo nixos-rebuild switch --flake .")))

(provide 'kitty-nix)
;;; kitty-nix.el ends here
