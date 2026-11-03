;;; early-init.el --- kittymax: before the first frame  -*- lexical-binding: t; -*-

;; Everything here exists to make startup fast and to stop the frame from
;; flashing: it runs before package setup and before the first frame is drawn.

;; Startup is a burst of allocation: never collect garbage until it is over
;; (kitty-core.el hands the threshold to gcmh afterwards).
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.6)

;; Every file loaded at startup goes through these handlers; none is needed yet.
(defvar kitty--file-name-handler-alist file-name-handler-alist)
(setq file-name-handler-alist nil)
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq file-name-handler-alist
                  (delete-dups (append file-name-handler-alist
                                       kitty--file-name-handler-alist)))))

;; Where the writable things live: keep the config directory (a git checkout)
;; clean. Native-compiled code goes to the cache too.
(defvar kitty-config-dir (file-name-as-directory user-emacs-directory)
  "The checkout this configuration is loaded from.")
(defvar kitty-data-dir
  (file-name-as-directory
   (expand-file-name "kittymax" (or (getenv "XDG_DATA_HOME") "~/.local/share")))
  "Persistent state: history, recent files, org-roam ...")
(defvar kitty-cache-dir
  (file-name-as-directory
   (expand-file-name "kittymax" (or (getenv "XDG_CACHE_HOME") "~/.cache")))
  "Disposable state: compiled configuration, native-comp cache, eln.")
(make-directory kitty-data-dir t)
(make-directory kitty-cache-dir t)

;; Packages come from Nix (see package.nix), already on `load-path'.  Their
;; autoloads are what package.el must still activate; package-quickstart
;; merges all of them into one file, so that costs one `load' instead of one
;; per package.  The file is rebuilt after Emacs is up whenever the Nix
;; package set (the site-lisp directories on `load-path') has changed.
(require 'seq)
(defvar kitty--package-key
  (mapconcat #'identity
             (seq-filter (lambda (d) (string-match-p "/share/emacs/site-lisp/?\\'" d))
                         load-path)
             ":")
  "Identifies the installed package set.")
(setq package-enable-at-startup t
      package-quickstart t
      package-quickstart-file (expand-file-name "package-quickstart.el" kitty-cache-dir))
(let ((key-file (expand-file-name "package-quickstart.key" kitty-cache-dir)))
  (unless (equal kitty--package-key
                 (and (file-exists-p key-file)
                      (with-temp-buffer (insert-file-contents key-file) (buffer-string))))
    (ignore-errors (delete-file package-quickstart-file)))
  (add-hook 'emacs-startup-hook
            (lambda ()
              (unless (file-exists-p package-quickstart-file)
                (run-with-idle-timer
                 1 nil
                 (lambda ()
                   (require 'package)
                   (package-quickstart-refresh)
                   (with-temp-file key-file (insert kitty--package-key))))))))

(when (boundp 'native-comp-eln-load-path)
  (startup-redirect-eln-cache (expand-file-name "eln/" kitty-cache-dir)))
(setq native-comp-async-report-warnings-errors 'silent
      native-comp-jit-compilation t)

;; No frame decoration or resizing while the theme and fonts load.
(setq frame-inhibit-implied-resize t
      frame-resize-pixelwise t
      inhibit-startup-screen t
      inhibit-startup-echo-area-message user-login-name
      initial-major-mode 'fundamental-mode
      initial-scratch-message nil
      load-prefer-newer t
      use-dialog-box nil
      use-file-dialog nil)
;; Start full screen (F11 toggles it).  KITTYMAX_FRAME=maximized keeps the
;; window decorations, KITTYMAX_FRAME=windowed leaves the size alone.
(let ((mode (pcase (getenv "KITTYMAX_FRAME")
              ("windowed" nil)
              ("maximized" 'maximized)
              (_ 'fullboth))))
  (when mode (push (cons 'fullscreen mode) default-frame-alist)))
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)
(push '(horizontal-scroll-bars) default-frame-alist)
(push '(internal-border-width . 8) default-frame-alist)
;; catppuccin mocha base, so there is no white flash before the theme loads
(push '(background-color . "#1e1e2e") default-frame-alist)
(push '(foreground-color . "#cdd6f4") default-frame-alist)
(push '(ns-appearance . dark) default-frame-alist)

;;; early-init.el ends here
