;;; kitty-cat.el --- a kitten that gives you a paw when you save  -*- lexical-binding: t; -*-

;;; Commentary:

;; Save a file and a small ASCII kitten in the echo area blinks, puts out its
;; paw and leaves a heart:
;;
;;    /\_/\  <3
;;   ( ^.^ )__o
;;    > ^ <   saved foo.el
;;
;; then "=^.^= saved foo.el" stays behind.  It lives in the echo area, so it
;; never touches the buffer, needs no package and works the same in a window,
;; in a terminal and on Windows.  It takes about a second and blocks nothing:
;; the frames run on timers and any key stops it.
;;
;; It only plays for the buffer you are looking at, not while the minibuffer
;; is asking something, and once per save even when a formatter saves again.
;; SPC u k turns it off (or `(kitty-cat-mode -1)' in local.el);
;; M-x kitty-cat-paw plays it whenever you need one.

;;; Code:

(require 'kitty-lib)
(require 'subr-x)

(defgroup kitty-cat nil
  "A kitten that gives you a paw when you save."
  :group 'convenience)

(defcustom kitty-cat-frame-delay 0.14
  "Seconds between two frames of the kitten."
  :type 'number)

(defcustom kitty-cat-hold 1.4
  "Seconds the paw stays out before the one-line summary replaces it."
  :type 'number)

;;;; Frames

(defconst kitty-cat--colors
  '((cat . "#cba6f7")                   ; mauve
    (face . "#a6e3a1")                  ; green eyes
    (paw . "#fab387")                   ; peach
    (heart . "#f38ba8")                 ; red
    (text . "#f5c2e7")                  ; pink
    (dim . "#6c7086"))                  ; overlay0
  "Catppuccin mocha, by role.")

(defun kitty-cat--paint (&rest segments)
  "A string from SEGMENTS: plain strings, or (ROLE . STRING) to colour."
  (mapconcat
   (lambda (seg)
     (if (stringp seg)
         seg
       (propertize (cdr seg) 'face
                   (list :foreground (alist-get (car seg) kitty-cat--colors)
                         :weight 'bold))))
   segments ""))

(defun kitty-cat--frame (eyes paw heart text)
  "One frame, three lines: the kitten with EYES (\"o.o\"), PAW at its side,
HEART above the paw and TEXT under it."
  (string-join
   (list
    (kitty-cat--paint '(cat . " /\\_/\\ ") "  " (cons 'heart heart))
    (kitty-cat--paint '(cat . "( ") (cons 'face eyes) '(cat . " )") (cons 'paw paw))
    (kitty-cat--paint '(cat . " > ^ < ") "   " (cons 'text text)))
   "\n"))

(defun kitty-cat-frames (name)
  "The frames for a file called NAME, as (STRING . SECONDS); the last stays."
  (let ((d kitty-cat-frame-delay))
    (list
     (cons (kitty-cat--frame "o.o" "" "" "") d)
     (cons (kitty-cat--frame "-.-" "" "" "") (* 0.7 d))     ; blink
     (cons (kitty-cat--frame "o.o" "_" "" "") d)
     (cons (kitty-cat--frame "^.^" "__" "" "") d)
     (cons (kitty-cat--frame "^.^" "__o" "" "") d)           ; the paw
     (cons (kitty-cat--frame "^.^" "__o" "<3" (concat "saved " name)) kitty-cat-hold)
     (cons (kitty-cat--paint '(cat . "=^.^=") " " '(dim . "saved ") (cons 'text name)) nil))))

;;;; Playing

(defvar kitty-cat--timer nil "The timer of the next frame, while the cat plays.")
(defvar kitty-cat--buffer nil "The buffer the cat is playing for.")

(defun kitty-cat--show (string)
  (let ((message-log-max nil))          ; frames stay out of *Messages*
    (message "%s" string)))

(defun kitty-cat-stop ()
  "Stop the kitten (any key does)."
  (when (timerp kitty-cat--timer) (cancel-timer kitty-cat--timer))
  (setq kitty-cat--timer nil
        kitty-cat--buffer nil)
  (remove-hook 'pre-command-hook #'kitty-cat-stop))

(defun kitty-cat-playing-p ()
  "Non-nil while the cat is playing."
  (timerp kitty-cat--timer))

(defun kitty-cat--play (frames)
  (pcase-let ((`(,string . ,delay) (car frames)))
    (if (active-minibuffer-window)
        (kitty-cat-stop)               ; never draw over a prompt
      (kitty-cat--show string)
      (if (and delay (cdr frames))
          (setq kitty-cat--timer (run-at-time delay nil #'kitty-cat--play (cdr frames)))
        (kitty-cat-stop)))))

(defun kitty-cat-paw (&optional name)
  "Have the kitten give you a paw, for a file called NAME (default: this buffer's)."
  (interactive)
  (kitty-cat-stop)
  (setq kitty-cat--buffer (current-buffer))
  (add-hook 'pre-command-hook #'kitty-cat-stop)
  (kitty-cat--play
   (kitty-cat-frames (or name (and buffer-file-name (file-name-nondirectory buffer-file-name))
                         (buffer-name)))))

;;;; On save

(define-minor-mode kitty-cat-mode
  "A kitten in the echo area gives you a paw whenever you save the buffer you are in."
  :global t
  :init-value t
  :group 'kitty-cat
  (unless kitty-cat-mode (kitty-cat-stop)))

(defun kitty-cat--should-play-p ()
  "Play for this save?  Only in an interactive Emacs, for the buffer in front of you."
  (and kitty-cat-mode
       (not noninteractive)
       (not executing-kbd-macro)
       (not (active-minibuffer-window))
       (eq (current-buffer) (window-buffer (selected-window)))
       ;; a formatter that saves again right after: one paw is enough
       (not (and (kitty-cat-playing-p) (eq kitty-cat--buffer (current-buffer))))))

(defun kitty-cat--after-save ()
  (when (kitty-cat--should-play-p)
    (kitty-cat-paw)))
(kitty-add-hook 'after-save-hook #'kitty-cat--after-save)

(provide 'kitty-cat)
;;; kitty-cat.el ends here
