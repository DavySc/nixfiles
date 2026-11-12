;;; kitty-rss.el --- RSS and Atom feeds with elfeed  -*- lexical-binding: t; -*-

;;; Commentary:

;; `SPC t r' opens elfeed and fetches every feed.  The feeds are an org file,
;; `elfeed.org' in `org-directory' (elfeed-org): one heading per feed, tags
;; are inherited, so a heading "Emacs :emacs:" with links under it tags all
;; of them.  `SPC t R' (or `SPC m F' in elfeed) opens that file; the first
;; time it is created with an example.  The database is in the data
;; directory (no-littering), not in the checkout.
;;
;; elfeed has evil-collection's Vim-style keys (j / k move, RET reads, q
;; quits); SPC is the leader, and SPC m has the rest (mark all read,
;; filters, star).

;;; Code:

(require 'kitty-lib)

(defvar org-directory)
(defvar rmh-elfeed-org-files)
(declare-function elfeed "elfeed")
(declare-function elfeed-update "elfeed")
(declare-function elfeed-show-tag "elfeed-show")
(declare-function elfeed-show-untag "elfeed-show")
(declare-function elfeed-search-tag-all "elfeed-search")
(declare-function elfeed-search-untag-all "elfeed-search")
(declare-function elfeed-search-set-filter "elfeed-search")
(declare-function elfeed-search-untag-all-unread "elfeed-search")
(declare-function elfeed-org "elfeed-org")

(defcustom kitty-rss-feeds-file nil
  "The org file listing the feeds; nil means elfeed.org in `org-directory'."
  :type '(choice (const nil) file) :group 'kittymax)

(defun kitty-rss-feeds-file ()
  "Absolute path of the feeds file (`org-directory' may be set in local.el)."
  (expand-file-name (or kitty-rss-feeds-file "elfeed.org")
                    (or (bound-and-true-p org-directory) "~/org/")))

(defconst kitty-rss--template
  "#+title: Feeds
# One link per heading, under a heading tagged :elfeed:.  Tags are inherited:
# every feed below \"Emacs\" is tagged emacs.  SPC t r reads them, G fetches.

* Feeds :elfeed:
** Emacs :emacs:
*** https://planet.emacslife.com/atom.xml
*** https://sachachua.com/blog/category/emacs-news/feed/
** Nix :nix:
*** https://nixos.org/blog/announcements-rss.xml
** News :news:
*** https://hnrss.org/frontpage?points=200
"
  "The feeds file written the first time it is needed.")

(defun kitty-rss--ensure-feeds-file ()
  "Create the feeds file from `kitty-rss--template' when it does not exist."
  (let ((file (kitty-rss-feeds-file)))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert kitty-rss--template)))
    file))

(setq elfeed-search-filter "@2-weeks-ago +unread"
      elfeed-search-title-max-width 100
      elfeed-search-trailing-width 30
      elfeed-show-entry-switch #'switch-to-buffer
      elfeed-sort-order 'descending
      url-queue-timeout 30)

(with-eval-after-load 'elfeed
  ;; elfeed-org reads the feeds file every time elfeed fetches.
  (when (require 'elfeed-org nil t)
    (setq rmh-elfeed-org-files (list (kitty-rss--ensure-feeds-file)))
    (elfeed-org)))

(defun kitty-rss ()
  "Open elfeed and fetch the feeds."
  (interactive)
  (if (not (require 'elfeed nil t))
      (user-error "elfeed is not installed")
    (setq rmh-elfeed-org-files (list (kitty-rss--ensure-feeds-file)))
    (elfeed)
    (elfeed-update)))

(defun kitty-rss-edit-feeds ()
  "Open the feeds file."
  (interactive)
  (find-file (kitty-rss--ensure-feeds-file)))

(defun kitty-rss-mark-all-read ()
  "Mark every entry in the search buffer read."
  (interactive)
  (goto-char (point-min))
  (push-mark (point-max) t t)
  (elfeed-search-untag-all-unread))

(defun kitty-rss-show-unread ()
  "Show the unread entries of the last two weeks."
  (interactive)
  (elfeed-search-set-filter "@2-weeks-ago +unread"))

(defun kitty-rss-show-recent ()
  "Show every entry of the last two weeks."
  (interactive)
  (elfeed-search-set-filter "@2-weeks-ago"))

(defun kitty-rss-show-starred ()
  "Show the starred entries."
  (interactive)
  (elfeed-search-set-filter "+star"))

(defun kitty-rss-star ()
  "Star the selected entries (in the list) or this entry."
  (interactive)
  (if (derived-mode-p 'elfeed-show-mode)
      (elfeed-show-tag 'star)
    (elfeed-search-tag-all 'star)))

(defun kitty-rss-unstar ()
  "Unstar the selected entries (in the list) or this entry."
  (interactive)
  (if (derived-mode-p 'elfeed-show-mode)
      (elfeed-show-untag 'star)
    (elfeed-search-untag-all 'star)))

(kitty-local-leader 'elfeed-search-mode
  "u" '("fetch" . elfeed-update)
  "a" '("mark all read" . kitty-rss-mark-all-read)
  "F" '("edit feeds" . kitty-rss-edit-feeds)
  "s" '("filter" . elfeed-search-live-filter)
  "f u" '("unread" . kitty-rss-show-unread)
  "f a" '("all, 2 weeks" . kitty-rss-show-recent)
  "f s" '("starred" . kitty-rss-show-starred)
  "*" '("star" . kitty-rss-star)
  "8" '("unstar" . kitty-rss-unstar))

(kitty-local-leader 'elfeed-show-mode
  "b" '("open in browser" . elfeed-show-visit)
  "y" '("copy link" . elfeed-show-yank)
  "n" '("next" . elfeed-show-next)
  "p" '("previous" . elfeed-show-prev)
  "*" '("star" . kitty-rss-star)
  "8" '("unstar" . kitty-rss-unstar))

;; Reading is prose: wrap, centre and size it like markdown.
(defun kitty--rss-show-setup ()
  (visual-line-mode 1)
  (setq-local shr-width 80
              shr-max-image-proportion 0.6
              line-spacing 0.2)
  (when (fboundp 'olivetti-mode)
    (setq-local olivetti-body-width 90)
    (olivetti-mode 1)))
(kitty-add-hook 'elfeed-show-mode-hook #'kitty--rss-show-setup)

(provide 'kitty-rss)
;;; kitty-rss.el ends here
