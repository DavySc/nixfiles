;;; kitty-splash-test.el --- tests for the start screen  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'kitty-splash)

(defun kitty-splash-test--mirror (s)
  (apply #'string (nreverse (mapcar (lambda (c) (pcase c (?/ ?\\) (?\\ ?/) (?\( ?\)) (?\) ?\() (_ c)))
                                    (append s nil)))))

(ert-deftest kitty-splash-cat-is-symmetric-at-every-size ()
  (dolist (rx '(7 11 17 24))
    (dolist (blink '(nil t))
      (dolist (whisker '(?= ?~))
        (cl-loop for row in (car (kitty-splash--cat rx blink nil whisker)) for i from 0
                 do (should (equal row (kitty-splash-test--mirror row))))))))

(ert-deftest kitty-splash-cat-rows-have-one-width ()
  (dolist (rx '(7 11 17 24))
    (let ((cat (kitty-splash--cat rx)))
      (should (= (length (car cat)) (kitty-splash--cat-height rx)))
      (dolist (row (car cat)) (should (= (string-width row) (kitty-splash--cat-width rx))))
      (cl-loop for row in (car cat) for roles in (cdr cat)
               do (should (= (length row) (length roles)))))))

(ert-deftest kitty-splash-cat-has-features ()
  (let ((text (string-join (car (kitty-splash--cat 17)) "\n")))
    (dolist (f '("|o|" "\\v/" "\\__/ \\__/" "====" "/\\"))
      (should (string-search f text)))))

(ert-deftest kitty-splash-blink-only-changes-the-eyes ()
  (let* ((open (car (kitty-splash--cat 17)))
         (shut (car (kitty-splash--cat 17 t)))
         (changed (cl-loop for a in open for b in shut for i from 0 unless (equal a b) collect i)))
    (should changed)
    (should (<= (- (apply #'max changed) (apply #'min changed)) 2))
    (should (string-search "---" (nth (cadr changed) shut)))))

(ert-deftest kitty-splash-twitch-only-moves-the-ear ()
  (let* ((a (car (kitty-splash--cat 17)))
         (b (car (kitty-splash--cat 17 nil t)))
         (changed (cl-loop for x in a for y in b for i from 0 unless (equal x y) collect i)))
    (should changed)
    ;; only rows of the ear (above the head's top row) differ
    (should (< (apply #'max changed) 4))))

(ert-deftest kitty-splash-every-visible-cell-has-a-colour-role ()
  (let ((cat (kitty-splash--cat 17)))
    (cl-loop for row in (car cat) for roles in (cdr cat)
             do (dotimes (i (length row))
                  (unless (= (aref row i) ?\s)
                    (should-not (= (aref roles i) ?\s)))))))

(ert-deftest kitty-splash-colours-are-valid-hex ()
  (dolist (c kitty-splash-gradient) (should (string-match-p "\\`#[0-9a-f]\\{6\\}\\'" c)))
  (dolist (role '(?o ?e ?y ?n ?m ?w))
    (dotimes (f 8)
      (should (string-match-p "\\`#[0-9a-f]\\{6\\}\\'" (kitty-splash--color-for role 3 f))))))

(ert-deftest kitty-splash-picks-the-biggest-cat-that-fits ()
  (should (= 24 (kitty-splash--pick-rx 200 60)))
  (should (= 24 (kitty-splash--pick-rx 200 38)))
  (should (= 17 (kitty-splash--pick-rx 200 37)))
  (should (= 11 (kitty-splash--pick-rx 120 29)))
  (should (= 7 (kitty-splash--pick-rx 80 24)))
  (should (= 5 (kitty-splash--pick-rx 80 21)))
  (should-not (kitty-splash--pick-rx 80 15))
  (should-not (kitty-splash--pick-rx 20 60)))

(ert-deftest kitty-splash-a-24-row-terminal-gets-a-cat ()
  (should (kitty-splash--pick-rx 80 24)))

(ert-deftest kitty-splash-everything-fits-the-window ()
  (dolist (size '((200 . 60) (200 . 40) (120 . 32) (80 . 28) (80 . 24) (80 . 20) (60 . 15) (40 . 10)))
    (let ((lines (kitty-splash--lines (car size) (cdr size) 0)))
      (should (<= (length lines) (cdr size)))
      (dolist (l lines) (should (<= (kitty-splash--line-width l) (car size)))))))

(ert-deftest kitty-splash-is-centred ()
  (with-temp-buffer
    (let* ((w 100) (h 45) (lines (kitty-splash--lines w h 0)))
      (kitty-splash--insert lines w h)
      (goto-char (point-min))
      ;; vertically: the blank lines above are about the same as below
      (let* ((total (count-lines (point-min) (point-max)))
             (above (progn (skip-chars-forward "\n") (1- (line-number-at-pos)))))
        (should (<= (abs (- above (- h total))) 2)))
      ;; horizontally: the title, the widest thing we can recognise, sits in the middle
      (goto-char (point-min))
      (re-search-forward "k i t t y m a x")
      (let* ((start (- (match-beginning 0) (line-beginning-position)))
             (width (string-width (match-string 0)))
             (left start) (right (- w start width)))
        (should (<= (abs (- left right)) 1))))))

(ert-deftest kitty-splash-opens-with-its-eyes-open-and-blinks-later ()
  (let ((open (string-join (kitty-splash--lines 100 45 0) "\n"))
        (blink (string-join (kitty-splash--lines 100 45 11) "\n")))
    (should (string-search "|o|" open))
    (should-not (string-search "|o|" blink))))

(ert-deftest kitty-splash-the-cat-is-centred ()
  (with-temp-buffer
    (let* ((w 100) (h 45) (rx (kitty-splash--pick-rx w h)))
      (kitty-splash--insert (kitty-splash--lines w h 0) w h)
      (goto-char (point-min))
      (re-search-forward "|o|")
      (let ((col (- (match-beginning 0) (line-beginning-position))))
        ;; the two eyes are symmetric about the centre; the first one found
        ;; is the left eye, so the middle is col + (distance between eyes)/2
        (should (<= (abs (- (+ col 1 (round (* rx 0.42))) (/ (1- w) 2.0))) 1.0))))))

(ert-deftest kitty-splash-opens-and-animates-only-while-visible ()
  (let ((kitty-splash-animate t))
    (unwind-protect
        (progn
          (kitty-splash)
          (should (timerp kitty-splash--timer))
          (should (get-buffer kitty-splash-buffer))
          (let ((f (buffer-local-value 'kitty-splash--frame (get-buffer kitty-splash-buffer))))
            (kitty-splash--tick)
            (should (> (buffer-local-value 'kitty-splash--frame (get-buffer kitty-splash-buffer)) f)))
          (should (string-search "kittymax"
                                 (with-current-buffer kitty-splash-buffer
                                   (replace-regexp-in-string " " "" (buffer-string)))))
          ;; hidden: the next tick stops the timer
          (switch-to-buffer (get-buffer-create "*other*"))
          (kitty-splash--tick)
          (should-not kitty-splash--timer))
      (kitty-splash--stop-timer)
      (ignore-errors (kill-buffer kitty-splash-buffer)))))

(ert-deftest kitty-splash-stops-animating-after-the-limit ()
  (let ((kitty-splash-animation-seconds 10))
    (unwind-protect
        (progn
          (kitty-splash)
          (setq kitty-splash--started (- (float-time) 60))
          (kitty-splash--tick)
          (should-not kitty-splash--timer))
      (kitty-splash--stop-timer)
      (ignore-errors (kill-buffer kitty-splash-buffer)))))

(ert-deftest kitty-splash-killing-the-buffer-stops-the-timer ()
  (kitty-splash)
  (should (timerp kitty-splash--timer))
  (kill-buffer kitty-splash-buffer)
  (should-not kitty-splash--timer))

;;; kitty-splash-test.el ends here
