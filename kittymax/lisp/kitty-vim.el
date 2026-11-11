;;; kitty-vim.el --- my-nvim's operators, text objects and cursors, on evil  -*- lexical-binding: t; -*-

;;; Commentary:

;; What my-nvim adds to Vim's editing keys, with the same keys:
;;
;;   ys{motion}{char} cs{old}{new} ds{char}, visual gs   surround (evil-surround;
;;                                                       * makes **bold** in markdown)
;;   ga{motion}{char}                                    align (evil-lion): gaip=
;;   gc{motion}, gcc                                     comment
;;   ia / aa  argument     if / af  call                 mini.ai's objects (evil-args,
;;   iq / aq  any quote    ib / ab  any bracket          tree-sitter, and here)
;;   iN( / aN( the next pair, iL( / aL( the last one
;;   S, van / vin                                        select / grow / shrink a syntax node
;;   C-n  cursor on the word, on to its next match       multiple cursors (evil-mc)
;;   SPC M  cursors on every match, Q  toggle a cursor here, ]C / [C  between them,
;;   gQ  bring the last cursors back, C-l  clear them
;;
;; Everything here needs evil; without it the module does nothing.  The text
;; objects and the operator are evil macros, evaluated when the module loads
;; so that a copy compiled without evil still works once evil is installed.

;;; Code:

(require 'kitty-lib)
(require 'subr-x)

(declare-function evil-define-key* "evil-core")
(declare-function evil-visual-select "evil-states")
(declare-function evil-select-quote "evil-common")
(declare-function evil-select-paren "evil-common")
(declare-function evil-read-key "evil-common")
(declare-function evil-mc-make-and-goto-next-match "evil-mc-cursor-make")
(declare-function evil-mc-make-all-cursors "evil-mc-cursor-make")
(declare-function evil-mc-undo-all-cursors "evil-mc-cursor-make")
(declare-function evil-mc-make-cursor-here "evil-mc-cursor-make")
(declare-function evil-mc-undo-cursor-at-pos "evil-mc-cursor-make")
(declare-function evil-mc-make-cursor-at-pos "evil-mc-cursor-make")
(declare-function evil-mc-skip-and-goto-next-cursor "evil-mc-cursor-make")
(declare-function evil-mc-skip-and-goto-prev-cursor "evil-mc-cursor-make")
(declare-function evil-mc-get-cursor-start "evil-mc-cursor-state")
(declare-function evil-mc-mode "evil-mc")
(defvar evil-inner-text-objects-map)
(defvar evil-outer-text-objects-map)
(defvar evil-normal-state-map)
(defvar evil-visual-state-map)
(defvar evil-surround-mode-map)
(defvar evil-surround-pairs-alist)
(defvar evil-mc-cursor-list)
(defvar evil-mc-key-map)

;;;; Ranges: the innermost pair around point, or the next one (mini.ai's cover_or_next)

(defun kitty--pick-range (ranges)
  "Of RANGES (lists (BEG END ...)), the smallest around point, else the nearest after it."
  (let ((pt (point)) around after)
    (dolist (r ranges)
      (when r
        (if (and (<= (car r) pt) (< pt (cadr r)))
            (when (or (null around) (< (- (cadr r) (car r)) (- (cadr around) (car around))))
              (setq around r))
          (when (and (> (car r) pt) (or (null after) (< (car r) (car after))))
            (setq after r)))))
    (or around after)))

(defun kitty--try (fn &rest args)
  "FN applied to ARGS, or nil if it signals an error."
  (condition-case nil (apply fn args) (error nil)))

(defun kitty--any-quote (beg end type count inclusive)
  "The quoted string around point (any of \" ' `), else the next on the line."
  (or (kitty--pick-range
       (mapcar (lambda (q) (kitty--try #'evil-select-quote q beg end type count inclusive))
               '(?\" ?' ?`)))
      (user-error "No quotes here")))

(defun kitty--any-bracket (beg end type count inclusive)
  "The bracket pair around point (any of () [] {}), else the next one."
  (or (kitty--pick-range
       (append
        (mapcar (lambda (p) (kitty--try #'evil-select-paren (car p) (cdr p) beg end type count inclusive))
                '((?\( . ?\)) (?\[ . ?\]) (?{ . ?})))
        ;; not inside any: the next opening bracket on the line
        (save-excursion
          (when (re-search-forward "[([{]" (line-end-position) t)
            (let ((open (char-before)))
              (list (kitty--try #'evil-select-paren open (pcase open (?\( ?\)) (?\[ ?\]) (_ ?}))
                                nil nil type count inclusive)))))))
      (user-error "No brackets here")))

(defun kitty--pair-chars (char)
  "The opening and closing characters for the object CHAR names, or nil."
  (pcase char
    ((or ?\( ?\) ?b) '(?\( . ?\)))
    ((or ?\[ ?\]) '(?\[ . ?\]))
    ((or ?{ ?} ?B) '(?{ . ?}))
    ((or ?< ?>) '(?< . ?>))
    ((or ?\" ?' ?`) (cons char char))
    (?q '(?\" . ?\"))))

(defun kitty--next-pair (char direction type count inclusive)
  "The pair CHAR names, next (DIRECTION 1) or last (-1) from point (mini.ai's N / L)."
  (let ((chars (or (kitty--pair-chars char) (user-error "No next/last for %c" char))))
    (save-excursion
      (if (> direction 0)
          (unless (search-forward (char-to-string (car chars)) nil t)
            (user-error "No next %c" (car chars)))
        (unless (search-backward (char-to-string (cdr chars)) nil t)
          (user-error "No last %c" (cdr chars))))
      (if (eq (car chars) (cdr chars))
          (evil-select-quote (car chars) nil nil type count inclusive)
        (evil-select-paren (car chars) (cdr chars) nil nil type count inclusive)))))

;;;; Syntax nodes (flash's S, Neovim 0.12's an / in)

(defun kitty--treesit-node-around (beg end)
  "The smallest tree-sitter node strictly larger than BEG..END."
  (when-let* ((node (treesit-node-on beg end)))
    (while (and node (<= (- (treesit-node-end node) (treesit-node-start node)) (- end beg)))
      (setq node (treesit-node-parent node)))
    node))

(defun kitty--treesit-node-inside (beg end)
  "The largest named node inside BEG..END and smaller than it."
  (when-let* ((node (treesit-node-on beg end)))
    (let ((child (treesit-node-child node 0 t)))
      (while (and child (>= (- (treesit-node-end child) (treesit-node-start child)) (- end beg)))
        (setq child (treesit-node-child child 0 t)))
      child)))

(defun kitty-node-range (beg end grow)
  "BEG..END grown to its parent syntax node (GROW) or shrunk to a child."
  (if (and (fboundp 'treesit-parser-list) (treesit-parser-list))
      (let ((node (if grow (kitty--treesit-node-around beg end) (kitty--treesit-node-inside beg end))))
        (if node (list (treesit-node-start node) (treesit-node-end node)) (list beg end)))
    ;; No tree-sitter in this buffer: expreg's guesses (words, lists, sentences ...).
    (if (and grow (require 'expreg nil t))
        (save-excursion
          (set-mark beg) (goto-char end) (activate-mark)
          (expreg-expand)
          (prog1 (list (region-beginning) (region-end)) (deactivate-mark)))
      (list beg end))))

(defun kitty-select-node ()
  "Select the syntax node at point; again to grow it (flash's S)."
  (interactive)
  (let ((r (if (evil-visual-state-p)
               (kitty-node-range (region-beginning) (region-end) t)
             (kitty-node-range (point) (min (point-max) (1+ (point))) t))))
    (evil-visual-select (car r) (cadr r))))

;;;; Multiple cursors (Neovim 0.13's, on evil-mc)

;; evil-mc's own keys sit under gr, which is the LSP's here (grr gri grn gra):
;; start it with an empty map and bind my-nvim's keys instead.
(defvar evil-mc-key-map (make-sparse-keymap))

(defun kitty--mc ()
  (unless (require 'evil-mc nil t) (user-error "evil-mc is not installed"))
  (unless (bound-and-true-p evil-mc-mode) (evil-mc-mode 1)))

(defun kitty-mc-next ()
  "A cursor on the word, then on to its next match (my-nvim's C-n)."
  (interactive)
  (kitty--mc)
  (evil-mc-make-and-goto-next-match))

(defun kitty-mc-all ()
  "A cursor on every match of the word (my-nvim's <leader>M)."
  (interactive)
  (kitty--mc)
  (evil-mc-make-all-cursors))

(defun kitty-mc-toggle ()
  "Add a cursor here, or remove the one that is here (Neovim's Q)."
  (interactive)
  (kitty--mc)
  (if (seq-find (lambda (c) (= (evil-mc-get-cursor-start c) (point))) evil-mc-cursor-list)
      (evil-mc-undo-cursor-at-pos (point))
    (evil-mc-make-cursor-here)))

(defvar-local kitty--mc-last nil
  "Where the cursors were when they were last cleared, for `kitty-mc-restore'.")

(defun kitty-mc-clear ()
  "Remove the extra cursors (Neovim's C-l), then redraw as C-l does."
  (interactive)
  (when (and (bound-and-true-p evil-mc-mode) evil-mc-cursor-list)
    (setq kitty--mc-last (mapcar #'evil-mc-get-cursor-start evil-mc-cursor-list))
    (evil-mc-undo-all-cursors))
  (recenter))

(defun kitty-mc-restore ()
  "Bring back the cursors the last C-l cleared (Neovim's gQ)."
  (interactive)
  (unless kitty--mc-last (user-error "No cursors to bring back"))
  (kitty--mc)
  (dolist (pos kitty--mc-last)
    (when (<= (point-min) pos (point-max)) (evil-mc-make-cursor-at-pos pos))))

(defun kitty-mc-goto-next ()
  "Go to the next cursor (Neovim's ]C)."
  (interactive)
  (kitty--mc)
  (evil-mc-skip-and-goto-next-cursor))

(defun kitty-mc-goto-prev ()
  "Go to the previous cursor (Neovim's [C)."
  (interactive)
  (kitty--mc)
  (evil-mc-skip-and-goto-prev-cursor))

;;;; Vim's C-a: the number under or after the cursor, up by COUNT
;;
;; C-x (Vim's decrement) stays Emacs's prefix key: C-x C-e, C-x b ... are the
;; way into the rest of Emacs.  Decrement with a negative count: -5 C-a.

(defun kitty-increment (count)
  "Add COUNT to the number under or after the cursor on this line (Vim's C-a)."
  (interactive "p")
  (let ((bol (line-beginning-position)) (eol (line-end-position)) (start (point)))
    ;; Inside a number: back to its first digit.  Else: the next digit on the line.
    (skip-chars-backward "0-9" bol)
    (unless (looking-at "[0-9]")
      (goto-char start)
      (unless (re-search-forward "[0-9]" eol t) (user-error "No number on this line"))
      (backward-char))
    (when (and (> (point) bol) (eq (char-before) ?-)) (backward-char))
    (looking-at "-?[0-9]+")
    (replace-match (number-to-string (+ (string-to-number (match-string 0)) count)) t t)
    ;; Vim leaves the cursor on the last digit.
    (backward-char)))

;;;; Definitions that need evil's macros

(defconst kitty--vim-evil-definitions
  '(progn
     (evil-define-operator kitty-comment (beg end)
       "Comment or uncomment (Neovim's gc; gcc for a line)."
       :move-point nil
       (comment-or-uncomment-region beg end))

     (evil-define-text-object kitty-inner-any-quote (count &optional beg end type)
       "Inside the nearest quotes of any kind (mini.ai's iq)."
       (kitty--any-quote beg end type count nil))
     (evil-define-text-object kitty-outer-any-quote (count &optional beg end type)
       "Around the nearest quotes of any kind (mini.ai's aq)."
       (kitty--any-quote beg end type count t))
     (evil-define-text-object kitty-inner-any-bracket (count &optional beg end type)
       "Inside the nearest brackets of any kind (mini.ai's ib)."
       (kitty--any-bracket beg end type count nil))
     (evil-define-text-object kitty-outer-any-bracket (count &optional beg end type)
       "Around the nearest brackets of any kind (mini.ai's ab)."
       (kitty--any-bracket beg end type count t))

     (evil-define-text-object kitty-inner-next (count &optional beg end type)
       "Inside the next pair of the next key's kind (mini.ai's iN)."
       (ignore beg end)
       (kitty--next-pair (evil-read-key) 1 type count nil))
     (evil-define-text-object kitty-outer-next (count &optional beg end type)
       "Around the next pair of the next key's kind (mini.ai's aN)."
       (ignore beg end)
       (kitty--next-pair (evil-read-key) 1 type count t))
     (evil-define-text-object kitty-inner-last (count &optional beg end type)
       "Inside the last pair of the next key's kind (mini.ai's iL)."
       (ignore beg end)
       (kitty--next-pair (evil-read-key) -1 type count nil))
     (evil-define-text-object kitty-outer-last (count &optional beg end type)
       "Around the last pair of the next key's kind (mini.ai's aL)."
       (ignore beg end)
       (kitty--next-pair (evil-read-key) -1 type count t))

     (evil-define-text-object kitty-node-outer (count &optional beg end type)
       "A syntax node around the selection; again for its parent (Neovim's an)."
       (ignore type)
       (kitty-node-range (or beg (point)) (or end (1+ (point))) t))
     (evil-define-text-object kitty-node-inner (count &optional beg end type)
       "A syntax node inside the selection (Neovim's in)."
       (ignore type)
       (kitty-node-range (or beg (point)) (or end (1+ (point))) nil)))
  "evil macro forms, evaluated when evil is there (see Commentary).")

;;;; Keys

(defun kitty--vim-objects ()
  "mini.ai's text objects."
  (let ((in evil-inner-text-objects-map) (out evil-outer-text-objects-map))
    (define-key in "q" #'kitty-inner-any-quote)
    (define-key out "q" #'kitty-outer-any-quote)
    (define-key in "b" #'kitty-inner-any-bracket)
    (define-key out "b" #'kitty-outer-any-bracket)
    (define-key in "N" #'kitty-inner-next)
    (define-key out "N" #'kitty-outer-next)
    (define-key in "L" #'kitty-inner-last)
    (define-key out "L" #'kitty-outer-last)
    (define-key in "n" #'kitty-node-inner)
    (define-key out "n" #'kitty-node-outer)
    (when (require 'evil-args nil t)
      (define-key in "a" #'evil-inner-arg)
      (define-key out "a" #'evil-outer-arg))
    (when (require 'evil-textobj-tree-sitter nil t)
      (define-key in "f" (eval '(evil-textobj-tree-sitter-get-textobj "call.inner") t))
      (define-key out "f" (eval '(evil-textobj-tree-sitter-get-textobj "call.outer") t)))))

(defun kitty--vim-surround ()
  "vim-surround's keys (ys cs ds), visual gs; S stays flash's node select."
  (when (require 'evil-surround nil t)
    (global-evil-surround-mode 1)
    (evil-define-key* 'visual evil-surround-mode-map
      (kbd "S") nil
      (kbd "gS") nil
      (kbd "gs") #'evil-surround-region)
    (kitty-add-hook 'markdown-mode-hook
                    (lambda ()
                      (setq-local evil-surround-pairs-alist
                                  (cons '(?* . ("**" . "**")) evil-surround-pairs-alist))))))

(defun kitty--vim-keys ()
  "The operators and cursor keys."
  (evil-define-key* '(normal visual) 'global
    (kbd "gc") #'kitty-comment
    (kbd "ga") #'evil-lion-left
    (kbd "S") #'kitty-select-node)
  (evil-define-key* 'normal 'global
    (kbd "C-n") #'kitty-mc-next
    (kbd "Q") #'kitty-mc-toggle
    (kbd "gQ") #'kitty-mc-restore
    (kbd "]C") #'kitty-mc-goto-next
    (kbd "[C") #'kitty-mc-goto-prev
    (kbd "C-l") #'kitty-mc-clear
    (kbd "C-a") #'kitty-increment))

(when (require 'evil nil t)
  (eval kitty--vim-evil-definitions t)
  (kitty--vim-objects)
  (kitty--vim-surround)
  (kitty--vim-keys))

(provide 'kitty-vim)
;;; kitty-vim.el ends here
