;;; kitty-ex.el --- a small ex command line on :  -*- lexical-binding: t; -*-

;;; Commentary:

;; `:' in meow's normal state asks for an ex command, as in vi:
;;
;;   :q  :qa        exit Emacs (asks about unsaved buffers)
;;   :q!            exit without asking
;;   :w [file]      save (or save as)         :wa     save everything
;;   :wq  :x        save this buffer, exit
;;   :e file        open                      :e!     revert
;;   :bd :bn :bp    kill / next / previous buffer
;;   :sp :vs [file] split below / right       :only   keep this window
;;   :close         close this window
;;   :42            go to line 42
;;   :%s/a/b/g      substitute (whole buffer; plain :s/a/b/ is this line,
;;                  or the region); the pattern is an Emacs regexp
;;
;; Anything else is tried as the name of an Emacs command (`:magit-status').

;;; Code:

(require 'subr-x)
(require 'cl-lib)

(defun kitty-ex--exit (bang)
  "Exit Emacs; with BANG without asking about unsaved buffers."
  (if bang (kill-emacs) (save-buffers-kill-terminal)))

(defun kitty-ex--substitute (whole regexp replacement flags)
  "Replace REGEXP with REPLACEMENT in the buffer (WHOLE), region or line.
FLAGS may contain g (every match on a line) and i (ignore case)."
  (let* ((case-fold-search (and (string-match-p "i" flags) t))
         (global (string-match-p "g" flags))
         (beg (cond (whole (point-min))
                    ((use-region-p) (region-beginning))
                    (t (line-beginning-position))))
         (end (cond (whole (point-max))
                    ((use-region-p) (region-end))
                    (t (line-end-position))))
         (count 0))
    (save-excursion
      (goto-char beg)
      (let ((end-marker (copy-marker end)))
        (while (and (< (point) end-marker) (re-search-forward regexp end-marker t))
          (replace-match replacement t)
          (cl-incf count)
          (unless global
            (forward-line 1)
            (unless (bolp) (goto-char (point-max)))))))
    (message "%d substitution%s" count (if (= count 1) "" "s"))
    count))

(defvar kitty-ex-commands
  `((("q" "quit" "qa" "qall" "quita" "quitall" "cq") . ,(lambda (bang _arg) (kitty-ex--exit bang)))
    (("w" "write") . ,(lambda (_bang arg)
                        (if (string-empty-p arg) (save-buffer) (write-file arg))))
    (("wa" "wall") . ,(lambda (_bang _arg) (save-some-buffers t)))
    (("wq" "x" "xit" "exit" "wqa" "xa" "xall")
     . ,(lambda (bang _arg)
          (when (and buffer-file-name (buffer-modified-p)) (save-buffer))
          (kitty-ex--exit bang)))
    (("e" "edit") . ,(lambda (bang arg)
                       (cond ((not (string-empty-p arg)) (find-file arg))
                             (bang (revert-buffer t t))
                             (t (user-error "Give a file name")))))
    (("bd" "bdelete" "bw" "bwipeout" "bun" "bunload") . ,(lambda (_bang _arg) (kill-current-buffer)))
    (("bn" "bnext") . ,(lambda (_bang _arg) (next-buffer)))
    (("bp" "bprevious" "bN" "bNext") . ,(lambda (_bang _arg) (previous-buffer)))
    (("sp" "split" "new") . ,(lambda (_bang arg)
                               (select-window (split-window-below))
                               (unless (string-empty-p arg) (find-file arg))))
    (("vs" "vsp" "vsplit" "vnew") . ,(lambda (_bang arg)
                                       (select-window (split-window-right))
                                       (unless (string-empty-p arg) (find-file arg))))
    (("on" "only") . ,(lambda (_bang _arg) (delete-other-windows)))
    (("clo" "close") . ,(lambda (_bang _arg) (delete-window)))
    (("noh" "nohlsearch") . ,(lambda (_bang _arg) (ignore))))
  "Alist of (NAMES . FUNCTION).  FUNCTION takes BANG (non-nil after !) and ARG.")

(defun kitty-ex--lookup (name)
  (cdr (seq-find (lambda (entry) (member name (car entry))) kitty-ex-commands)))

;;;###autoload
(defun kitty-ex-run (line)
  "Run the ex command LINE (without the leading colon)."
  (let ((line (string-trim (string-trim-left line ":"))))
    (cond
     ((string-empty-p line) nil)
     ;; :42
     ((string-match "\\`[0-9]+\\'" line)
      (goto-char (point-min))
      (forward-line (1- (string-to-number line))))
     ;; :s/a/b/g and :%s/a/b/g
     ((string-match "\\`\\(%\\)?s\\(.\\)\\(.*?\\)\\2\\(.*?\\)\\(?:\\2\\([gi]*\\)\\)?\\'" line)
      (kitty-ex--substitute (and (match-string 1 line) t) (match-string 3 line)
                            (match-string 4 line) (or (match-string 5 line) "")))
     (t
      (string-match "\\`\\([^ \t!]+\\)\\(!\\)?[ \t]*\\(.*\\)\\'" line)
      (let* ((name (match-string 1 line))
             (bang (and (match-string 2 line) t))
             (arg (match-string 3 line))
             (fn (kitty-ex--lookup name)))
        (cond
         (fn (funcall fn bang arg))
         ((commandp (intern-soft name)) (call-interactively (intern-soft name)))
         (t (user-error "Not an editor command: %s" name))))))))

;;;###autoload
(defun kitty-ex ()
  "Read an ex command (:q, :w, :wq, :e file ...) and run it."
  (interactive)
  (kitty-ex-run (read-from-minibuffer ":" nil nil nil 'kitty-ex-history)))

(defvar kitty-ex-history nil)

(provide 'kitty-ex)
;;; kitty-ex.el ends here
