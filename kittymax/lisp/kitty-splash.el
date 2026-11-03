;;; kitty-splash.el --- the start screen  -*- lexical-binding: t; -*-

;;; Commentary:

;; A cat, centred in the window and sized to it, in catppuccin colours that
;; shimmer down its outline; it blinks, twitches an ear and wiggles its
;; whiskers.  Below it: the keys worth knowing and the recent files.
;;
;; The cat is generated, not drawn: a head from a squared ellipse, ears
;; standing on its corners, features at computed positions, so it is
;; symmetric and exactly as wide as it claims at every size.
;;
;; The animation costs nothing when it is not visible: a timer runs only
;; while the splash is on screen, and stops after `kitty-splash-animation-seconds'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup kitty-splash nil "The start screen." :group 'kittymax)

(defcustom kitty-splash-animate t
  "Animate the cat." :type 'boolean :group 'kitty-splash)
(defcustom kitty-splash-interval 0.35
  "Seconds between frames." :type 'number :group 'kitty-splash)
(defcustom kitty-splash-animation-seconds 300
  "Stop animating after this long (the screen then stays as it is)."
  :type 'number :group 'kitty-splash)

(defconst kitty-splash-buffer "*kittymax*")

;;;; The cat

(defun kitty-splash--cat-height (rx)
  "Rows of the cat whose head is RX columns either side of the centre."
  (let* ((ry (* rx 0.39)) (eh (max 3 (round (* rx 0.2)))))
    (+ eh (floor (* 2 ry)) 5)))

(defun kitty-splash--cat-width (rx) (+ (* 2 rx) 7))

(defun kitty-splash--cat (rx &optional blink twitch whisker)
  "A cat head, RX columns either side of the centre.
Return (ROWS . ROLES): ROWS are strings of the same width, ROLES strings of
one letter per cell saying what it is: o outline, e ear, y eye, n nose,
m mouth, w whisker, space for nothing.  BLINK closes the eyes, TWITCH moves
the right ear, WHISKER is the character the whiskers are drawn with."
  (let* ((ry (* rx 0.39))
         (eh (max 3 (round (* rx 0.2))))
         (top eh)
         (cy (+ eh ry 0.7))
         (denom (+ ry 1.4))
         (w (kitty-splash--cat-width rx))
         (cx (/ w 2))
         (h (kitty-splash--cat-height rx))
         (whisker (or whisker ?=))
         (chars (let ((v (make-vector h nil)))
                  (dotimes (i h) (aset v i (make-vector w ?\s))) v))
         (roles (let ((v (make-vector h nil)))
                  (dotimes (i h) (aset v i (make-vector w ?\s))) v)))
    (cl-labels
        ((put (x y c role)
           (when (and (>= x 0) (< x w) (>= y 0) (< y h))
             (aset (aref chars y) x c)
             (aset (aref roles y) x role)))
         (text (x y s role)
           (dotimes (i (length s)) (put (+ x i) y (aref s i) role)))
         (hw (y)
           (let ((tt (/ (- y cy) denom)))
             (unless (> (abs tt) 1)
               (round (* rx (expt (- 1.0 (expt (abs tt) 3)) (/ 1.0 3))))))))
      ;; head
      (let ((last (cl-loop for y from top to (1- h) when (hw y) maximize y)))
        (cl-loop
         for y from top to last
         for half = (hw y)
         when half
         do (let ((tt (/ (- y cy) denom))
                  (xl (- cx half)) (xr (+ cx half)))
              (when (or (= y top) (= y last))
                (cl-loop for x from (1+ xl) below xr
                         do (put x y (if (< y cy) ?_ ?‾) ?o)))
              (put xl y (cond ((< (abs tt) 0.3) ?\() ((< y cy) ?/) (t ?\\)) ?o)
              (put xr y (cond ((< (abs tt) 0.3) ?\)) ((< y cy) ?\\) (t ?/)) ?o))))
      ;; ears, standing on the top corners of the head
      (let* ((axl (- cx (round (* rx 0.58))))
             (axr (+ (- (* 2 cx) axl) (if twitch -1 0))))
        (dotimes (r eh)
          (put (- axl r) r ?/ ?e)       (put (+ axl 1 r) r ?\\ ?e)
          (put (+ axr r) r ?\\ ?e)      (put (- axr 1 r) r ?/ ?e)))
      ;; eyes
      (let ((ey (- (round cy) 2)) (ex (round (* rx 0.42))))
        (dolist (s '(-1 1))
          (let ((x (- (+ cx (* s ex)) 1)))
            (if blink
                (text x (1+ ey) "---" ?y)
              (text x ey ".-." ?y) (text x (1+ ey) "|o|" ?y) (text x (+ ey 2) "'-'" ?y))))
        ;; nose, mouth, whiskers
        (let ((ny (+ ey 3))
              (wl (max 3 (round (* rx 0.22)))))
          (text (1- cx) ny "\\v/" ?n)
          (put cx (1+ ny) ?| ?n)
          (text (- cx 4) (+ ny 2) "\\__/ \\__/" ?m)
          (dolist (d '(0 1))
            (let ((len (- wl d)))
              (text (+ (- cx rx) 2 d) (+ ny d) (make-string len whisker) ?w)
              (text (- (+ cx rx) 2 d len -1) (+ ny d) (make-string len whisker) ?w))))))
    (cons (mapcar (lambda (r) (apply #'string (append r nil))) (append chars nil))
          (mapcar (lambda (r) (apply #'string (append r nil))) (append roles nil)))))

;;;; Colour: catppuccin mocha

(defconst kitty-splash-gradient
  '("#f5c2e7" "#cba6f7" "#b4befe" "#89b4fa" "#74c7ec" "#94e2d5" "#a6e3a1" "#94e2d5"
    "#74c7ec" "#89b4fa" "#b4befe" "#cba6f7")
  "Pink, mauve, lavender, blue, sapphire, teal, green and back.")

(defun kitty-splash--color-for (role row frame)
  (pcase role
    (?e "#f5c2e7") (?y "#a6e3a1") (?n "#f38ba8") (?m "#fab387") (?w "#a6adc8")
    (_ (nth (mod (+ row (/ frame 2)) (length kitty-splash-gradient)) kitty-splash-gradient))))

(defun kitty-splash--paint (row roles index frame)
  "ROW (a string) coloured by ROLES for row INDEX at animation FRAME."
  (let ((out "") (i 0) (n (length row)))
    (while (< i n)
      (let* ((role (aref roles i)) (j i))
        (while (and (< j n) (= (aref roles j) role)) (cl-incf j))
        (setq out (concat out
                          (if (= role ?\s)
                              (substring row i j)
                            (propertize (substring row i j) 'face
                                        (list :foreground (kitty-splash--color-for role index frame)
                                              :weight 'bold)))))
        (setq i j)))
    out))

(defun kitty-splash--rainbow (string frame)
  (let ((i -1))
    (mapconcat (lambda (c)
                 (cl-incf i)
                 (propertize (string c) 'face
                             (list :foreground (nth (mod (+ i (/ frame 2)) (length kitty-splash-gradient))
                                                    kitty-splash-gradient)
                                   :weight 'bold)))
               string " ")))

;;;; Layout

(defun kitty-splash--pick-rx (width height)
  "The biggest cat that fits WIDTH x HEIGHT with the text below it, or nil."
  (cl-find-if (lambda (rx)
                (and (>= width (+ (kitty-splash--cat-width rx) 6))
                     (>= height (+ (kitty-splash--cat-height rx) 10))))
              '(24 17 11 7 5)))

(defun kitty-splash--hint (key description)
  (concat (propertize key 'face '(:foreground "#cba6f7" :weight bold)) " "
          (propertize description 'face '(:foreground "#a6adc8"))))

(defun kitty-splash--recent (limit)
  (require 'recentf)
  (unless recentf-list (ignore-errors (recentf-load-list)))
  (seq-take (seq-filter #'file-exists-p (bound-and-true-p recentf-list)) limit))

(defun kitty-splash--lines (width height frame)
  "The splash as a list of lines for a WIDTH x HEIGHT window at FRAME.
A line is a string, or (:button LABEL FILE) for a recent file."
  (let* ((rx (kitty-splash--pick-rx width height))
         (cat (when rx
                (kitty-splash--cat rx (= (mod frame 12) 11) (= (mod frame 31) 7)
                                   (if (= (mod frame 9) 4) ?~ ?=))))
         (lines nil))
    (when cat
      (cl-loop for row in (car cat) for roles in (cdr cat) for i from 0
               do (push (kitty-splash--paint row roles i frame) lines))
      (push "" lines))
    (push (kitty-splash--rainbow "kittymax" frame) lines)
    (push (propertize
           (if after-init-time
               (format "meow-powered emacs  ·  started in %.2fs"
                       (float-time (time-subtract after-init-time before-init-time)))
             "meow-powered emacs")
           'face '(:foreground "#7f849c" :slant italic))
          lines)
    (push "" lines)
    ;; three columns of equal width, so they line up when the block is centred
    (let* ((cells '(("SPC SPC" "commands") ("SPC ." "find file") ("SPC /" "ripgrep")
                    ("SPC p p" "project") ("SPC g g" "magit") ("SPC o a" "agenda")
                    ("SPC h t" "tutorial") (":q" "quit") ("SPC h s" "startup")))
           (cw (apply #'max (mapcar (lambda (c) (+ (string-width (car c)) 1 (string-width (cadr c)))) cells))))
      (if (>= width (+ (* 3 cw) 8 2))
          (dotimes (row 3)
            (push (mapconcat
                   (lambda (c)
                     (let ((cell (kitty-splash--hint (car c) (cadr c))))
                       (concat cell (make-string (- cw (string-width cell)) ?\s))))
                   (seq-subseq cells (* row 3) (* (1+ row) 3)) "    ")
                  lines))
        ;; too narrow for three columns: the essentials, one per line
        (dolist (i '(0 1 7))
          (let ((c (nth i cells)))
            (push (kitty-splash--hint (car c) (cadr c)) lines)))))
    ;; recent files get whatever room is left (a header, a gap, and the margins)
    (let* ((room (- height (length lines) 4))
           (recent (when (> room 0) (kitty-splash--recent (min 5 room)))))
      (when recent
        (push "" lines)
        (push (propertize "recent" 'face '(:foreground "#6c7086")) lines)
        (dolist (f recent) (push (list :button (abbreviate-file-name f) f) lines))))
    (nreverse lines)))

(defun kitty-splash--line-width (line)
  (string-width (if (stringp line) line (nth 1 line))))

(defun kitty-splash--insert (lines width height)
  "Insert LINES centred in a WIDTH x HEIGHT window."
  (insert (make-string (max 1 (/ (- height (length lines)) 2)) ?\n))
  (dolist (line lines)
    (insert (make-string (max 0 (/ (- width (kitty-splash--line-width line)) 2)) ?\s))
    (if (stringp line)
        (insert line)
      (let ((file (nth 2 line)))
        (insert-text-button (nth 1 line)
                            'action (lambda (_) (find-file file))
                            'follow-link t
                            'face '(:foreground "#89b4fa"))))
    (insert "\n")))

;;;; Buffer, animation

(defvar kitty-splash--timer nil)
(defvar kitty-splash--started 0.0)
(defvar-local kitty-splash--frame 0)

(defun kitty-splash--size ()
  (let ((win (get-buffer-window (get-buffer kitty-splash-buffer) t)))
    (if win
        (cons (window-body-width win) (window-body-height win))
      (cons (frame-width) (frame-height)))))

(defun kitty-splash--render ()
  "Redraw the splash buffer for the current window size and frame."
  (when-let* ((buf (get-buffer kitty-splash-buffer)))
    (with-current-buffer buf
      (let* ((size (kitty-splash--size))
             (inhibit-read-only t)
             (inhibit-modification-hooks t))
        (erase-buffer)
        (kitty-splash--insert (kitty-splash--lines (car size) (cdr size) kitty-splash--frame)
                              (car size) (cdr size))
        (goto-char (point-min))
        (set-buffer-modified-p nil)))))

(defun kitty-splash--stop-timer ()
  (when (timerp kitty-splash--timer) (cancel-timer kitty-splash--timer))
  (setq kitty-splash--timer nil))

(defun kitty-splash--start-timer ()
  (kitty-splash--stop-timer)
  (when kitty-splash-animate
    (setq kitty-splash--started (float-time)
          kitty-splash--timer (run-with-timer kitty-splash-interval kitty-splash-interval
                                              #'kitty-splash--tick))))

(defun kitty-splash--tick ()
  "One animation step; stops itself when the splash is hidden or has run long enough."
  (let ((buf (get-buffer kitty-splash-buffer)))
    (if (not (and buf kitty-splash-animate
                  (get-buffer-window buf 'visible)
                  (< (- (float-time) kitty-splash--started) kitty-splash-animation-seconds)))
        (kitty-splash--stop-timer)
      (with-current-buffer buf (cl-incf kitty-splash--frame))
      (kitty-splash--render))))

(defun kitty-splash--on-window-change ()
  "Re-centre when the window changes size (full screen, a split ...)."
  (kitty-splash--render)
  (when (and (null kitty-splash--timer) kitty-splash-animate
             (get-buffer-window (get-buffer kitty-splash-buffer) 'visible))
    (kitty-splash--start-timer)))

(define-derived-mode kitty-splash-mode special-mode "Splash"
  "Major mode of the start screen."
  (setq-local cursor-type nil
              cursor-in-non-selected-windows nil
              truncate-lines t
              mode-line-format nil
              buffer-undo-list t)
  (face-remap-add-relative 'hl-line :inherit 'default)
  (add-hook 'window-configuration-change-hook #'kitty-splash--on-window-change nil t)
  (add-hook 'kill-buffer-hook #'kitty-splash--stop-timer nil t))

;;;###autoload
(defun kitty-splash ()
  "Show the start screen."
  (interactive)
  (let ((buf (get-buffer-create kitty-splash-buffer)))
    (with-current-buffer buf
      (unless (derived-mode-p 'kitty-splash-mode) (kitty-splash-mode))
      (setq kitty-splash--frame 0))
    (pop-to-buffer-same-window buf)
    (kitty-splash--render)
    (kitty-splash--start-timer)
    buf))

(setq initial-buffer-choice #'kitty-splash)

(provide 'kitty-splash)
;;; kitty-splash.el ends here
