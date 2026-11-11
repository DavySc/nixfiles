;;; kitty-ui.el --- catppuccin mocha, modeline, fonts, icons  -*- lexical-binding: t; -*-

;;; Commentary:

;; Catppuccin Mocha everywhere (the theme package also themes org, magit,
;; markdown, dired, vertico, corfu ... through the faces they share), a
;; doom-modeline with evil's state in it, nerd icons, and which-key as the
;; discoverability layer for the SPC tree.

;;; Code:

(require 'kitty-lib)

;;;; Theme

(setq catppuccin-flavor 'mocha
      catppuccin-enlarge-headings t
      catppuccin-italic-comments t
      catppuccin-height-title-1 1.5
      catppuccin-height-title-2 1.3
      catppuccin-height-title-3 1.15)

(defun kitty--load-theme ()
  (when (require 'catppuccin-theme nil t)
    (load-theme 'catppuccin t)))

;; Themes are loaded before the first frame is drawn: no flash of white.
(kitty--load-theme)

(defun kitty-toggle-flavor ()
  "Cycle the catppuccin flavor (mocha, macchiato, frappe, latte)."
  (interactive)
  (setq catppuccin-flavor
        (pcase catppuccin-flavor
          ('mocha 'macchiato) ('macchiato 'frappe) ('frappe 'latte) (_ 'mocha)))
  (when (fboundp 'catppuccin-reload) (catppuccin-reload))
  (message "catppuccin %s" catppuccin-flavor))

;;;; Fonts

(defcustom kitty-font-mono "JetBrainsMono Nerd Font"
  "Fixed pitch font." :type 'string :group 'kittymax)
(defcustom kitty-font-sans (if (kitty-windows-p) "Segoe UI" "Inter")
  "Variable pitch font, used for prose (markdown, org)." :type 'string :group 'kittymax)
(defcustom kitty-font-size 13
  "Font size in points." :type 'integer :group 'kittymax)

(defun kitty--font-available-p (family)
  (and (display-graphic-p) (find-font (font-spec :family family))))

(defun kitty-setup-fonts (&optional frame)
  "Apply the fonts to FRAME (default: the selected one) when it is graphical."
  (with-selected-frame (or frame (selected-frame))
    (when (display-graphic-p)
      (when (kitty--font-available-p kitty-font-mono)
        (set-face-attribute 'default nil :family kitty-font-mono
                            :height (* 10 kitty-font-size))
        (set-face-attribute 'fixed-pitch nil :family kitty-font-mono))
      (when (kitty--font-available-p kitty-font-sans)
        (set-face-attribute 'variable-pitch nil :family kitty-font-sans
                            :height 1.05)))))

(if (daemonp)
    (add-hook 'after-make-frame-functions #'kitty-setup-fonts)
  (add-hook 'emacs-startup-hook #'kitty-setup-fonts))

;;;; Icons and the modeline

(setq nerd-icons-font-family "Symbols Nerd Font Mono")

(setq doom-modeline-height 28
      doom-modeline-bar-width 4
      doom-modeline-icon t
      doom-modeline-buffer-file-name-style 'truncate-upto-project
      doom-modeline-buffer-encoding nil
      doom-modeline-indent-info nil
      doom-modeline-modal t
      doom-modeline-modal-icon nil
      doom-modeline-modal-modern-icon nil
      doom-modeline-minor-modes nil
      doom-modeline-checker-simple-format t
      doom-modeline-vcs-max-length 24
      doom-modeline-lsp t
      doom-modeline-env-version nil
      doom-modeline-support-imenu nil)

(add-hook 'emacs-startup-hook (lambda () (when (require 'doom-modeline nil t)
                                           (doom-modeline-mode 1))))

;; doom-modeline's `modals' segment shows evil's state (N / I / V / M) itself.

;;;; which-key: the SPC tree, shown after a short wait

(setq which-key-idle-delay 0.35
      which-key-idle-secondary-delay 0.05
      which-key-sort-order 'which-key-key-order-alpha
      which-key-add-column-padding 2
      which-key-max-description-length 32
      which-key-popup-type 'side-window
      which-key-side-window-location 'bottom
      which-key-separator "  "
      which-key-prefix-prefix "+")
(add-hook 'emacs-startup-hook #'which-key-mode)

;;;; Small visual aids

(setq-default cursor-type 'box)
(setq blink-cursor-blinks 3)

(when (require 'rainbow-delimiters nil t)
  (kitty-add-hook 'prog-mode-hook #'rainbow-delimiters-mode))

(when (require 'hl-todo nil t)
  (kitty-add-hook 'prog-mode-hook #'hl-todo-mode)
  (kitty-add-hook 'text-mode-hook #'hl-todo-mode))

;; Dim the window you are not in a little.
(setq window-divider-default-right-width 1
      window-divider-default-bottom-width 1
      window-divider-default-places t)
(add-hook 'emacs-startup-hook #'window-divider-mode)

(provide 'kitty-ui)
;;; kitty-ui.el ends here
