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

;; Platform differences (Nix vs native Windows) live in one small file.
(defvar kitty-config-dir (file-name-as-directory user-emacs-directory)
  "The checkout this configuration is loaded from.")
(load (expand-file-name "lisp/kitty-platform" kitty-config-dir) nil t)

;; Where the writable things live: keep the config directory (a git checkout)
;; clean. Native-compiled code goes to the cache too.
(defvar kitty-data-dir (kitty-state-dir 'data)
  "Persistent state: history, recent files, ELPA packages on Windows ...")
(defvar kitty-cache-dir (kitty-state-dir 'cache)
  "Disposable state: compiled configuration, native-comp cache, eln.")
(make-directory kitty-data-dir t)
(make-directory kitty-cache-dir t)

;; Packages.  Under Nix they come from the profile (see package.nix) and are
;; already on `load-path'.  Anywhere else (native Windows) package.el installs
;; them from ELPA and MELPA into the data directory, on first start
;; (lisp/kitty-packages.el).  Either way package.el activates them, and
;; package-quickstart merges all their autoloads into one file, so that costs
;; one `load' instead of one per package.  The file is rebuilt after Emacs is
;; up whenever the installed package set has changed.
(defvar kitty-nix-p (kitty-nix-p)
  "Non-nil when the packages are provided by Nix.")
;; (Never inside this checkout, whatever the source.)
(setq package-user-dir (expand-file-name "elpa/" kitty-data-dir))
(unless kitty-nix-p
  (setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                           ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                           ("melpa" . "https://melpa.org/packages/"))
        package-archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1)))
  ;; Signature checks need gpg, which a plain Windows does not have.
  (unless (executable-find "gpg") (setq package-check-signature nil)))
(defvar kitty--package-key (kitty-package-key kitty-nix-p (bound-and-true-p package-user-dir))
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
                   (with-temp-file key-file
                     (insert (kitty-package-key kitty-nix-p package-user-dir)))))))))

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
