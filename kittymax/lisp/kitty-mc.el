;;; kitty-mc.el --- multiple cursors on top of meow's beacon  -*- lexical-binding: t; -*-

;;; Commentary:

;; meow does multiple cursors without copying the buffer state around: a
;; *secondary selection* (the "grab") says where cursors may exist, the
;; selection type says where they go inside it (every match, every line, the
;; same column), and the keyboard macro you record is replayed at each of
;; them.  That scales to thousands of cursors, and every meow command works.
;; The commands here are the shortcuts on top, so it feels like
;; VS Code's Ctrl-D and Kakoune's `s':
;;
;;   C       add the next match of the selection (or of the word at point)
;;   M       cursors on every match in the buffer
;;   SPC k l a cursor on every line of the region (C-u: same column)
;;   SPC k r   cursors on every regexp match inside the region
;;
;; then edit as usual: `c' changes at every cursor, `i'/`a' insert/append at
;; each, `d' deletes, `s' kills; <escape> leaves the cursors.  For anything
;; else, record a macro (F3 ... F4) and it is applied to all of them.

;;; Code:

(require 'kitty-lib)
(require 'subr-x)
(require 'cl-lib)

(declare-function meow-beacon-mode-p "meow-util")
(declare-function meow--make-selection "meow-command")
(declare-function meow--select "meow-command")
(declare-function meow--cancel-selection "meow-command")
(declare-function meow--cancel-second-selection "meow-command")
(declare-function meow--beacon-remove-overlays "meow-beacon")
(declare-function meow--switch-state "meow-util")
(declare-function meow-line "meow-command")
(declare-function meow-normal-mode-p "meow-util")
(defvar mouse-secondary-overlay)
(defvar meow--beacon-overlays)

(defun kitty-mc-active-p ()
  "Non-nil when this buffer has extra cursors or a cursor scope."
  (and (featurep 'meow)
       (or (meow-beacon-mode-p)
           (and (overlayp mouse-secondary-overlay)
                (eq (overlay-buffer mouse-secondary-overlay) (current-buffer))))))

(defun kitty-mc--scope ()
  "The scope (BEG . END) cursors may live in, or nil."
  (when (and (overlayp mouse-secondary-overlay)
             (eq (overlay-buffer mouse-secondary-overlay) (current-buffer)))
    (cons (overlay-start mouse-secondary-overlay)
          (overlay-end mouse-secondary-overlay))))

(defun kitty-mc--set-scope (beg end)
  "Make BEG..END the scope of the cursors, keeping point and the selection."
  (let ((deactivate-mark nil))
    (save-mark-and-excursion
      (set-mark end)
      (goto-char beg)
      (secondary-selection-from-region))))

(defun kitty-mc--remember-search (text)
  "Make TEXT, literally, the current search: meow places cursors on its matches."
  (let ((re (regexp-quote text)))
    (add-to-history 'regexp-search-ring re regexp-search-ring-max)
    re))

(defun kitty-mc--bounds-at-point ()
  "Bounds of the selection, else of the symbol (or word) at point."
  (cond ((use-region-p) (cons (region-beginning) (region-end)))
        ((bounds-of-thing-at-point 'symbol))
        ((bounds-of-thing-at-point 'word))
        (t (user-error "Nothing to put a cursor on here"))))

(defun kitty-mc--select-text (beg end)
  "Select BEG..END as a search selection: its text is what cursors follow."
  (kitty-mc--remember-search (buffer-substring-no-properties beg end))
  (meow--select (meow--make-selection '(select . visit) beg end) t))

(defun kitty-mc--ensure-selection ()
  "Select the text cursors should follow.  Return its (BEG . END)."
  (let ((b (kitty-mc--bounds-at-point)))
    (unless (and (use-region-p)
                 (equal (meow--selection-type-safe) '(select . visit)))
      (kitty-mc--select-text (car b) (cdr b)))
    (cons (region-beginning) (region-end))))

(defun meow--selection-type-safe ()
  "The meow selection type, nil when there is none."
  (and (boundp 'meow--selection) (use-region-p) (car meow--selection)))

(defun kitty-mc--search-literal ()
  (or (car regexp-search-ring) (user-error "No search text")))

;;;###autoload
(defun kitty-mc-mark-all ()
  "Put a cursor on every match of the selection (the symbol at point if none).
With a grab already set, only matches inside it count."
  (interactive)
  (kitty-mc--ensure-selection)
  (unless (kitty-mc--scope)
    (kitty-mc--set-scope (point-min) (point-max)))
  (message "%d cursors" (1+ (kitty-mc--count-matches))))

(defun kitty-mc--count-matches ()
  "Matches of the current search inside the scope, other than the selection."
  (let ((scope (kitty-mc--scope)) (n 0)
        (re (kitty-mc--search-literal)) (case-fold-search nil))
    (when scope
      (save-excursion
        (goto-char (car scope))
        (while (re-search-forward re (cdr scope) t)
          (unless (and (use-region-p)
                       (= (match-beginning 0) (region-beginning))
                       (= (match-end 0) (region-end)))
            (cl-incf n)))))
    n))

;;;###autoload
(defun kitty-mc-mark-next ()
  "Add a cursor on the next match of the selection (the symbol at point if none)."
  (interactive)
  (let* ((sel (kitty-mc--ensure-selection))
         (scope (or (kitty-mc--scope) sel))
         (re (kitty-mc--search-literal))
         (case-fold-search nil)
         (found (save-excursion
                  (goto-char (cdr scope))
                  (when (re-search-forward re nil t)
                    (cons (match-beginning 0) (match-end 0))))))
    (if found
        (progn (kitty-mc--set-scope (car scope) (cdr found))
               (message "%d cursors" (1+ (kitty-mc--count-matches))))
      (message "No more matches"))))

;;;###autoload
(defun kitty-mc-mark-prev ()
  "Add a cursor on the previous match of the selection."
  (interactive)
  (let* ((sel (kitty-mc--ensure-selection))
         (scope (or (kitty-mc--scope) sel))
         (re (kitty-mc--search-literal))
         (case-fold-search nil)
         (found (save-excursion
                  (goto-char (car scope))
                  (when (re-search-backward re nil t)
                    (cons (match-beginning 0) (match-end 0))))))
    (if found
        (progn (kitty-mc--set-scope (car found) (cdr scope))
               (message "%d cursors" (1+ (kitty-mc--count-matches))))
      (message "No more matches"))))

;;;###autoload
(defun kitty-mc-unmark-last ()
  "Drop the cursor that was added last (the farthest match in the scope)."
  (interactive)
  (let ((scope (kitty-mc--scope)) (re (car regexp-search-ring))
        (case-fold-search nil) last-end)
    (unless (and scope re (use-region-p)) (user-error "No cursors"))
    (save-excursion
      (goto-char (car scope))
      (while (re-search-forward re (cdr scope) t)
        (unless (and (= (match-beginning 0) (region-beginning))
                     (= (match-end 0) (region-end)))
          (push (match-end 0) last-end))))
    ;; LAST-END holds the match ends, farthest first; shrink to the one before.
    (cond ((cdr last-end)
           (kitty-mc--set-scope (car scope) (cadr last-end)))
          (last-end
           (kitty-mc--set-scope (region-beginning) (region-end))))))

;;;###autoload
(defun kitty-mc-mark-lines (&optional same-column)
  "A cursor for every line of the region (the paragraph if there is none).
Edits then apply to each whole line: `a' appends to each, `i' prepends.
With a prefix argument (SAME-COLUMN) the cursors keep the current column."
  (interactive "P")
  (let* ((beg (if (use-region-p) (region-beginning)
                (save-excursion (backward-paragraph) (skip-chars-forward "\n") (point))))
         (end (if (use-region-p) (region-end)
                (save-excursion (forward-paragraph) (skip-chars-backward "\n") (point))))
         (first (save-excursion (goto-char beg) (line-beginning-position)))
         (last (save-excursion (goto-char end) (line-end-position))))
    (when (use-region-p) (meow--cancel-selection))
    (goto-char first)
    (kitty-mc--set-scope first last)
    (if same-column
        (message "cursors in the same column on %d lines"
                 (count-lines first last))
      (meow-line 1)
      (message "%d lines" (count-lines first last)))))

;;;###autoload
(defun kitty-mc-mark-regexp (regexp)
  "Cursors on every match of REGEXP inside the region (the buffer if none)."
  (interactive (list (read-regexp "Cursors on matches of" nil 'regexp-search-ring)))
  (let* ((beg (if (use-region-p) (region-beginning) (point-min)))
         (end (if (use-region-p) (region-end) (point-max)))
         (case-fold-search nil))
    (when (use-region-p) (meow--cancel-selection))
    (goto-char beg)
    (unless (re-search-forward regexp end t)
      (user-error "No match for %s" regexp))
    (let ((mb (match-beginning 0)) (me (match-end 0)))
      (add-to-history 'regexp-search-ring regexp regexp-search-ring-max)
      (meow--select (meow--make-selection '(select . visit) mb me) t)
      (kitty-mc--set-scope beg end)
      (message "%d cursors" (1+ (kitty-mc--count-matches))))))

;;;###autoload
(defun kitty-mc-clear ()
  "Leave multiple-cursor mode: forget the scope and the selection."
  (interactive)
  (when (featurep 'meow)
    (when (fboundp 'meow--beacon-remove-overlays) (meow--beacon-remove-overlays))
    (meow--cancel-second-selection)
    (when (overlayp mouse-secondary-overlay) (delete-overlay mouse-secondary-overlay))
    (meow--cancel-selection)
    (when (meow-beacon-mode-p) (meow--switch-state 'normal))))

(provide 'kitty-mc)
;;; kitty-mc.el ends here
