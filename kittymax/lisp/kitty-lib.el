;;; kitty-lib.el --- loader and small macros  -*- lexical-binding: t; -*-

;;; Commentary:

;; `kitty-load' loads a module from its byte-compiled copy in the cache
;; (compiling it first when the source is newer), so the Lisp in this
;; repository is read as machine code at startup, and Emacs native-compiles it
;; in the background on top of that.  The repository itself stays clean.
;;
;; The leader tree is built from `kitty-keymap' and `kitty-prefix'; mode
;; specific keys (SPC m ...) from `kitty-local-leader'.

;;; Code:

(require 'subr-x)
(require 'project)

(defvar kitty-config-dir)
(defvar kitty-cache-dir)
;; Special before they are bound in `kitty--compile' (bytecomp is not loaded
;; yet at startup, and binding an unknown variable in a lexical-binding file
;; would silently be a lexical binding that the compiler never sees).
(defvar byte-compile-dest-file-function)
(defvar byte-compile-warnings)

(defgroup kittymax nil "kittymax." :group 'convenience)

(defvar kitty--load-times nil "Alist (MODULE . SECONDS) of what `kitty-load' spent.")

(defun kitty--elc-dir ()
  (let ((dir (expand-file-name "elc/" kitty-cache-dir)))
    (make-directory dir t)
    dir))

(defun kitty--stale-p (src dest)
  "Non-nil when DEST is missing or older than SRC or than this library."
  (or (not (file-exists-p dest))
      (file-newer-than-file-p src dest)
      (let ((lib (locate-library "kitty-lib.el")))
        (and lib (file-newer-than-file-p lib dest)))))

(defun kitty--compile (src dest)
  "Byte-compile SRC to DEST.  Return non-nil on success."
  (require 'bytecomp)
  (let ((byte-compile-dest-file-function (lambda (_) dest))
        (byte-compile-warnings '(not obsolete docstrings docstrings-wide
                                     docstrings-non-ascii-quotes))
        (inhibit-message t))
    (condition-case err
        (byte-compile-file src)
      (error (message "kittymax: compiling %s failed: %s" src err) nil))))

(defun kitty-load (feature)
  "Load module FEATURE (a symbol) from its compiled copy, building it if needed.
A module that fails is reported in *Warnings* and skipped: the modules after
it still load, so one bug does not turn the whole editor into stock Emacs."
  (let* ((t0 (float-time))
         (name (symbol-name feature))
         (src (locate-file name load-path '(".el")))
         (dest (and src (expand-file-name (concat name ".elc") (kitty--elc-dir)))))
    (condition-case err
        (cond
         ((null src) (display-warning 'kittymax (format "no module %s" name) :error))
         ((and (or (not (kitty--stale-p src dest)) (kitty--compile src dest))
               (file-exists-p dest))
          (load dest nil 'nomessage 'nosuffix))
         (t (load src nil 'nomessage 'nosuffix)))
      (error
       (display-warning 'kittymax
                        (format "Loading %s failed: %s" name (error-message-string err))
                        :error)))
    (push (cons feature (- (float-time) t0)) kitty--load-times)
    feature))

(defun kitty-startup-report ()
  "Show what startup cost, module by module."
  (interactive)
  (message "kittymax: %.2fs to the first frame, %d GCs.  Modules: %s"
           (float-time (time-subtract after-init-time before-init-time))
           gcs-done
           (mapconcat (lambda (m) (format "%s %.0fms" (car m) (* 1000 (cdr m))))
                      (reverse kitty--load-times) ", ")))

;;;; Hooks that cannot take the editor down

;; Emacs stops running a mode's hooks at the first error, and switches
;; font-lock on only after they have all run: one failing function in
;; `prog-mode-hook' therefore costs syntax highlighting in every code buffer,
;; and nothing says why.  `kitty-add-hook' adds a function so that an error
;; in it is shown in *Warnings* and the hooks after it still run.

(defun kitty--safe-hook-function (fn)
  "A symbol naming a wrapper of FN that reports its errors instead of raising them."
  (let ((name (intern (format "kitty-safe/%s"
                              (if (symbolp fn) fn (md5 (prin1-to-string fn)))))))
    (unless (fboundp name)
      (defalias name
        (lambda (&rest args)
          (condition-case err
              (apply fn args)
            (error
             (display-warning
              'kittymax
              (format "%s failed in %s: %s"
                      (if (symbolp fn) fn "a hook function")
                      (or (bound-and-true-p major-mode) "this buffer")
                      (error-message-string err))
              :error)
             nil)))))
    name))

(defun kitty-add-hook (hook function &optional depth local)
  "Like `add-hook', but an error in FUNCTION is reported, not raised."
  (add-hook hook (kitty--safe-hook-function function) depth local))

;;;; Keymaps for the leader tree

(defun kitty-keymap (&rest bindings)
  "A sparse keymap from BINDINGS, a flat list of KEY DEFINITION pairs.
A DEFINITION may be (\"description\" . command), which which-key shows."
  (let ((map (make-sparse-keymap)))
    (while bindings
      (define-key map (kbd (pop bindings)) (pop bindings)))
    map))

(defun kitty-prefix (label &rest bindings)
  "A prefix keymap named LABEL (shown by which-key) holding BINDINGS."
  (cons label (apply #'kitty-keymap bindings)))

;;;; Local leader: SPC m, the keys of the current major mode

(defvar kitty--local-leaders (make-hash-table :test #'eq)
  "Major mode -> keymap of its SPC m bindings.")

(defun kitty-local-leader (mode &rest bindings)
  "Add BINDINGS (see `kitty-keymap') to the SPC m keymap of major mode MODE."
  (let ((map (or (gethash mode kitty--local-leaders)
                 (puthash mode (make-sparse-keymap) kitty--local-leaders))))
    (while bindings
      (define-key map (kbd (pop bindings)) (pop bindings)))
    map))

(defun kitty--local-leader-map ()
  "The SPC m keymap for the current buffer: its mode and the modes it derives from."
  (let (maps (mode major-mode))
    (while mode
      (when-let* ((m (gethash mode kitty--local-leaders)))
        (push m maps))
      (setq mode (get mode 'derived-mode-parent)))
    (when maps (make-composed-keymap (nreverse maps)))))

(defconst kitty-local-leader-binding
  '(menu-item "+mode" nil :filter (lambda (_) (kitty--local-leader-map)))
  "Bind this to SPC m: it resolves to the keymap of the current mode.")

;;;; Odds and ends

(defmacro kitty-when-executable (program &rest body)
  "Run BODY when PROGRAM is on `exec-path'."
  (declare (indent 1))
  `(when (executable-find ,program) ,@body))

(defun kitty-project-root ()
  "The root of the current project, or `default-directory'."
  (or (when-let* ((p (project-current))) (project-root p))
      default-directory))

(provide 'kitty-lib)
;;; kitty-lib.el ends here
