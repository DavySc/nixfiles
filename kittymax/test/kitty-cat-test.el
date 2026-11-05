;;; kitty-cat-test.el --- tests for the kitten on save  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-config-dir default-directory)
(require 'kitty-lib)
(require 'kitty-cat)

(defmacro kitty-test--capturing-messages (var &rest body)
  "Run BODY with every echo-area message pushed onto VAR (newest first)."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'message)
              (lambda (fmt &rest args)
                (when fmt (push (substring-no-properties (apply #'format fmt args)) ,var)))))
     ,@body))

(defun kitty-test--wait-cat ()
  (let ((n 0))
    (while (and (kitty-cat-playing-p) (< n 100))
      (accept-process-output nil 0.05)
      (cl-incf n))))

(ert-deftest kitty-cat-frames-are-three-lines-then-one ()
  (let ((frames (kitty-cat-frames "notes.org")))
    (dolist (f (butlast frames))
      (should (= 3 (length (split-string (car f) "\n"))))
      (should (numberp (cdr f))))
    (should (equal "=^.^= saved notes.org" (substring-no-properties (car (car (last frames))))))
    (should-not (cdr (car (last frames))))
    ;; the paw comes out, and the heart goes over it
    (let* ((paw (split-string (substring-no-properties (car (nth 5 frames))) "\n")))
      (should (string-match-p "( \\^\\.\\^ )__o" (nth 1 paw)))
      (should (string-match-p "<3" (nth 0 paw)))
      (should (string-match-p "saved notes.org" (nth 2 paw))))))

(ert-deftest kitty-cat-frames-are-coloured ()
  (let ((s (car (car (kitty-cat-frames "a")))))
    (should (get-text-property 1 'face s))))

(ert-deftest kitty-cat-plays-every-frame-and-ends-on-one-line ()
  (let ((kitty-cat-frame-delay 0.01) (kitty-cat-hold 0.01) msgs)
    (kitty-test--capturing-messages msgs
      (with-temp-buffer
        (kitty-cat-paw "x.el")
        (should (kitty-cat-playing-p))
        (kitty-test--wait-cat)))
    (should-not (kitty-cat-playing-p))
    (should (= (length (kitty-cat-frames "x.el")) (length msgs)))
    (should (equal "=^.^= saved x.el" (car msgs)))
    (should-not (memq #'kitty-cat-stop pre-command-hook))))

(ert-deftest kitty-cat-any-key-stops-it ()
  (let ((kitty-cat-frame-delay 10) msgs)
    (kitty-test--capturing-messages msgs
      (with-temp-buffer
        (kitty-cat-paw "x.el")
        (should (memq #'kitty-cat-stop pre-command-hook))
        (run-hooks 'pre-command-hook)))
    (should-not (kitty-cat-playing-p))
    (should (= 1 (length msgs)))))

(ert-deftest kitty-cat-stays-out-of-the-messages-log ()
  (let ((kitty-cat-frame-delay 0.01) (kitty-cat-hold 0.01))
    (with-current-buffer (messages-buffer)
      (let ((before (buffer-size)))
        (with-temp-buffer (kitty-cat-paw "x.el") (kitty-test--wait-cat))
        (should (= before (buffer-size)))))))

(ert-deftest kitty-cat-when-it-plays-on-save ()
  (let ((noninteractive nil))
    (with-temp-buffer
      (cl-letf (((symbol-function 'window-buffer) (lambda (&rest _) (current-buffer))))
        (should (kitty-cat--should-play-p))
        (let ((kitty-cat-mode nil)) (should-not (kitty-cat--should-play-p)))
        (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t)))
          (should-not (kitty-cat--should-play-p)))
        ;; a second save while it plays (a formatter): no restart
        (let ((kitty-cat-frame-delay 10))
          (cl-letf (((symbol-function 'message) #'ignore))
            (kitty-cat-paw "x"))
          (should-not (kitty-cat--should-play-p))
          (kitty-cat-stop)))
      ;; a buffer saved in the background (save-some-buffers): no kitten
      (cl-letf (((symbol-function 'window-buffer) (lambda (&rest _) (get-buffer-create " other"))))
        (should-not (kitty-cat--should-play-p))))
    ;; batch Emacs never plays
    (let ((noninteractive t))
      (with-temp-buffer
        (cl-letf (((symbol-function 'window-buffer) (lambda (&rest _) (current-buffer))))
          (should-not (kitty-cat--should-play-p)))))))

(ert-deftest kitty-cat-plays-after-a-real-save ()
  (let ((noninteractive nil) (kitty-cat-frame-delay 10) msgs
        (file (make-temp-file "kitty-cat" nil ".txt")))
    (with-current-buffer (find-file-noselect file)
      (cl-letf (((symbol-function 'window-buffer) (lambda (&rest _) (current-buffer))))
        (kitty-test--capturing-messages msgs
          (insert "meow")
          (save-buffer)))
      (should (kitty-cat-playing-p))
      (kitty-cat-stop)
      (kill-buffer))
    (should (string-match-p "( o\\.o )" (car msgs)))))

(provide 'kitty-cat-test)
;;; kitty-cat-test.el ends here
