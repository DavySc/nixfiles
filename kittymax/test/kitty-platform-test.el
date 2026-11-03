;;; kitty-platform-test.el --- tests for the Nix / Windows differences  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'kitty-platform)
(require 'kitty-packages)
(require 'package)   ; before any stubbing: loading it later would overwrite them
(defvar kitty-test--dir (file-name-directory (or load-file-name buffer-file-name)))

(defun kitty-test--env (&rest pairs)
  "A getenv function over the plist PAIRS."
  (lambda (name) (plist-get pairs (intern (concat ":" name)))))

;;;; State directories

(ert-deftest kitty-platform-windows-state-goes-to-localappdata ()
  (let ((env (kitty-test--env :LOCALAPPDATA "C:/Users/me/AppData/Local")))
    (should (equal "C:/Users/me/AppData/Local/kittymax/data/" (kitty-state-dir 'data 'windows-nt env)))
    (should (equal "C:/Users/me/AppData/Local/kittymax/cache/" (kitty-state-dir 'cache 'windows-nt env)))))

(ert-deftest kitty-platform-windows-backslashes-become-slashes ()
  (let ((env (kitty-test--env :LOCALAPPDATA "C:\\Users\\me\\AppData\\Local")))
    (should (equal "C:/Users/me/AppData/Local/kittymax/data/" (kitty-state-dir 'data 'windows-nt env)))))

(ert-deftest kitty-platform-windows-without-localappdata-falls-back-to-home ()
  (should (equal (file-name-as-directory (expand-file-name "~/AppData/Local/kittymax/data"))
                 (kitty-state-dir 'data 'windows-nt (kitty-test--env)))))

(ert-deftest kitty-platform-unix-state-follows-xdg ()
  (let ((env (kitty-test--env :XDG_DATA_HOME "/x/data" :XDG_CACHE_HOME "/x/cache")))
    (should (equal "/x/data/kittymax/" (kitty-state-dir 'data 'gnu/linux env)))
    (should (equal "/x/cache/kittymax/" (kitty-state-dir 'cache 'gnu/linux env))))
  (should (equal (file-name-as-directory (expand-file-name "~/.local/share/kittymax"))
                 (kitty-state-dir 'data 'gnu/linux (kitty-test--env))))
  (should (equal (file-name-as-directory (expand-file-name "~/.cache/kittymax"))
                 (kitty-state-dir 'cache 'gnu/linux (kitty-test--env)))))

(ert-deftest kitty-platform-windows-p ()
  (should (kitty-windows-p 'windows-nt))
  (should-not (kitty-windows-p 'gnu/linux))
  (should-not (kitty-windows-p 'darwin)))

;;;; Where packages come from

(ert-deftest kitty-platform-package-source ()
  (should (eq 'nix (kitty-package-source (kitty-test--env :KITTYMAX_PACKAGES "nix"))))
  (should (eq 'none (kitty-package-source (kitty-test--env :KITTYMAX_PACKAGES "none"))))
  (should (eq 'elpa (kitty-package-source (kitty-test--env :KITTYMAX_PACKAGES "elpa"))))
  (should (eq 'elpa (kitty-package-source (kitty-test--env))))
  (should (kitty-nix-p (kitty-test--env :KITTYMAX_PACKAGES "nix")))
  (should-not (kitty-nix-p (kitty-test--env))))

(ert-deftest kitty-platform-package-key-changes-with-installed-packages ()
  (let ((dir (make-temp-file "elpa" t)))
    (let ((empty (kitty-package-key nil dir)))
      (make-directory (expand-file-name "meow-1.0" dir))
      (let ((one (kitty-package-key nil dir)))
        (should-not (equal empty one))
        (make-directory (expand-file-name "magit-3.0" dir))
        (should-not (equal one (kitty-package-key nil dir)))
        ;; order of creation does not matter
        (should (equal (kitty-package-key nil dir) (kitty-package-key nil dir))))))
  (should (equal "none" (kitty-package-key nil "/does/not/exist/elpa"))))

(ert-deftest kitty-platform-nix-package-key-uses-the-profile ()
  (let ((load-path '("/nix/store/aaa-env/share/emacs/site-lisp" "/usr/share/emacs/lisp"
                     "/nix/store/bbb-env/share/emacs/site-lisp/")))
    (should (equal "/nix/store/aaa-env/share/emacs/site-lisp:/nix/store/bbb-env/share/emacs/site-lisp/"
                   (kitty-package-key t nil)))))

;;;; The package list

(defun kitty-test--nix-packages ()
  "Package names listed in package.nix's `packageList'."
  (let* ((file (expand-file-name "../package.nix" kitty-test--dir))
         (text (with-temp-buffer (insert-file-contents file) (buffer-string)))
         (start (string-match "packageList =" text))
         (end (string-match "\n    \\];" text start))
         (body (substring text start end))
         (body (replace-regexp-in-string "#.*" "" body))
         (body (replace-regexp-in-string "\\`[^[]*\\[" "" body))
         names)
    (dolist (tok (split-string body "[ \t\n]+" t))
      (unless (string-match-p "\\." tok) ; treesit-grammars.with-all-grammars is nix-only
        (push (intern tok) names)))
    (nreverse names)))

(ert-deftest kitty-packages-match-package-nix ()
  "The ELPA list and the Nix list must name the same packages."
  (let ((nix (sort (kitty-test--nix-packages) #'string<))
        (elpa (sort (copy-sequence kitty-packages) #'string<)))
    (should (equal nix elpa))))

(ert-deftest kitty-packages-have-no-duplicates ()
  (should (= (length kitty-packages) (length (delete-dups (copy-sequence kitty-packages))))))

(ert-deftest kitty-packages-windows-leaves-out-the-unix-only-ones ()
  (let ((win (kitty-wanted-packages 'windows-nt)))
    (dolist (p kitty-packages-not-on-windows) (should-not (memq p win)))
    (should (memq 'meow win))
    (should (memq 'magit win))
    (should (= (length win) (- (length kitty-packages) (length kitty-packages-not-on-windows)))))
  (should (equal kitty-packages (kitty-wanted-packages 'gnu/linux))))

(defun kitty-test--call-with-stubs (stubs thunk)
  "Call THUNK with the functions in STUBS (an alist of symbol -> function) replaced.
Plain `fset', restored afterwards: `cl-letf' does not intercept every call here."
  (let ((olds (mapcar (lambda (s) (cons (car s) (symbol-function (car s)))) stubs)))
    (unwind-protect
        (progn (dolist (s stubs) (fset (car s) (cdr s)))
               (funcall thunk))
      (dolist (o olds) (fset (car o) (cdr o))))))

(defun kitty-test--with-install-stubs (installed thunk &optional extra)
  "Run THUNK with package.el stubbed; INSTALLED lists the packages already there.
EXTRA is more stubs.  Return (INSTALLS REFRESHES)."
  (let ((installs nil) (refreshes 0))
    (kitty-test--call-with-stubs
     (append extra
             (list (cons 'package-installed-p (lambda (p &rest _) (and (memq p installed) t)))
                   (cons 'package-refresh-contents (lambda (&rest _) (cl-incf refreshes)))
                   (cons 'package-install (lambda (p &rest _) (push p installs)))
                   (cons 'redisplay #'ignore)))
     thunk)
    (list (nreverse installs) refreshes)))

(ert-deftest kitty-packages-missing-ones-are-found ()
  (kitty-test--with-install-stubs '(meow magit)
    (lambda ()
      (let ((missing (kitty-missing-packages)))
        (should-not (memq 'meow missing))
        (should-not (memq 'magit missing))
        (should (memq 'vertico missing))))))

(ert-deftest kitty-packages-ensure-installs-only-what-is-missing ()
  (let* ((have (cl-remove-if (lambda (p) (memq p '(meow vertico))) (kitty-wanted-packages)))
         (result (kitty-test--with-install-stubs have #'kitty-ensure-packages
                                                 (list (cons 'kitty-package-source (lambda (&rest _) 'elpa))))))
    (should (equal '(meow vertico) (sort (copy-sequence (car result)) #'string<)))
    (should (= 1 (cadr result)))))

(ert-deftest kitty-packages-ensure-does-nothing-when-nothing-is-missing ()
  (should (equal '(nil 0)
                 (kitty-test--with-install-stubs (kitty-wanted-packages) #'kitty-ensure-packages
                                                 (list (cons 'kitty-package-source (lambda (&rest _) 'elpa)))))))

(ert-deftest kitty-packages-ensure-does-nothing-under-nix-or-none ()
  (dolist (src '(nix none))
    (should (equal '(nil 0)
                   (kitty-test--with-install-stubs nil #'kitty-ensure-packages
                                                   (list (cons 'kitty-package-source (lambda (&rest _) src))))))))

(ert-deftest kitty-packages-a-failing-install-is-reported-and-the-rest-go-on ()
  (let ((warnings nil) (installed nil))
    (kitty-test--call-with-stubs
     (list (cons 'package-refresh-contents #'ignore)
           (cons 'redisplay #'ignore)
           (cons 'display-warning (lambda (_type msg &rest _) (push msg warnings)))
           (cons 'package-install (lambda (p &rest _) (if (eq p 'vertico) (error "boom") (push p installed)))))
     (lambda () (kitty-install-packages '(meow vertico magit))))
    (should (equal '(meow magit) (nreverse installed)))
    (should (seq-find (lambda (w) (string-match-p "vertico failed" w)) warnings))))

(ert-deftest kitty-packages-an-unreachable-archive-is-reported ()
  (let ((warnings nil) (installed nil))
    (kitty-test--call-with-stubs
     (list (cons 'package-refresh-contents (lambda (&rest _) (error "offline")))
           (cons 'redisplay #'ignore)
           (cons 'display-warning (lambda (_type msg &rest _) (push msg warnings)))
           (cons 'package-install (lambda (p &rest _) (push p installed))))
     (lambda () (kitty-install-packages '(meow))))
    (should (seq-find (lambda (w) (string-match-p "offline" w)) warnings))
    (should (equal '(meow) installed))))

;;; kitty-platform-test.el ends here
