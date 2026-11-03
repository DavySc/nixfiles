;;; kitty-platform.el --- where am I running, where do my files go  -*- lexical-binding: t; -*-

;;; Commentary:

;; The same configuration runs on NixOS (packages from Nix, state under XDG
;; directories) and on native Windows (packages from ELPA/MELPA through
;; package.el, state under %LOCALAPPDATA%).  This file is the only place that
;; knows the difference at startup; early-init.el loads it by path, before
;; anything else, so it must depend on nothing.

;;; Code:

(defun kitty-windows-p (&optional system)
  "Non-nil on native Windows (SYSTEM defaults to `system-type')."
  (eq (or system system-type) 'windows-nt))

(defun kitty-state-dir (kind &optional system getenv)
  "The directory for KIND, `data' (kept) or `cache' (disposable), with a trailing slash.
SYSTEM and GETENV (a function of a variable name) default to the real ones."
  (let* ((getenv (or getenv #'getenv))
         (data (eq kind 'data)))
    (file-name-as-directory
     (if (kitty-windows-p system)
         ;; %LOCALAPPDATA% has backslashes; Emacs wants slashes
         (let ((base (subst-char-in-string
                      ?\\ ?/ (or (funcall getenv "LOCALAPPDATA")
                                  (expand-file-name "~/AppData/Local")))))
           (concat (directory-file-name base) (if data "/kittymax/data" "/kittymax/cache")))
       (let ((base (or (funcall getenv (if data "XDG_DATA_HOME" "XDG_CACHE_HOME"))
                       (expand-file-name (if data "~/.local/share" "~/.cache")))))
         (concat (directory-file-name base) "/kittymax"))))))

(defun kitty-package-source (&optional getenv)
  "Where packages come from: `nix', `elpa', or `none'.
Set by the environment variable KITTYMAX_PACKAGES.  The Nix wrapper sets it to
nix; unset means elpa (install from ELPA/MELPA on first start); none is for
tests and for people who manage packages themselves."
  (pcase (funcall (or getenv #'getenv) "KITTYMAX_PACKAGES")
    ("nix" 'nix)
    ("none" 'none)
    (_ 'elpa)))

(defun kitty-nix-p (&optional getenv)
  "Non-nil when the packages come from Nix (already on `load-path')."
  (eq (kitty-package-source getenv) 'nix))

(defun kitty-package-key (nix-p elpa-dir)
  "A string that changes whenever the set of installed packages does.
With Nix: the site-lisp directories of the profile.  Otherwise: the contents of
ELPA-DIR (one directory per package and version)."
  (if nix-p
      (mapconcat #'identity
                 (cl-remove-if-not (lambda (d) (string-match-p "/share/emacs/site-lisp/?\\'" d))
                                   load-path)
                 ":")
    (if (and elpa-dir (file-directory-p elpa-dir))
        (md5 (mapconcat #'identity
                        (sort (directory-files elpa-dir nil "\\`[^.]") #'string<)
                        ":"))
      "none")))

(eval-when-compile (require 'cl-lib))
(require 'cl-lib)

(provide 'kitty-platform)
;;; kitty-platform.el ends here
