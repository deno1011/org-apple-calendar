;;; org-apple-calendar-tests.el --- Tests for org-apple-calendar -*- lexical-binding: t; -*-

;; ert suite. Stubs the L1 transport boundary (`org-apple-calendar--jxa-run')
;; so nothing touches EventKit. Focus: recurrence (org repeater -> EKRecurrenceRule).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'org-apple-calendar)

;;; --- recurrence parsing (pure) ---------------------------------------------

(ert-deftest org-apple-calendar-test-timestamp-recurrence ()
  "An org repeater maps to a (:freq :interval) recurrence plist (or nil)."
  (dolist (case '(("<2026-07-01 Wed +1w>"  (:freq weekly  :interval 1))
                  ("<2026-07-01 Wed +2w>"  (:freq weekly  :interval 2))
                  ("<2026-07-01 Wed +3d>"  (:freq daily   :interval 3))
                  ("<2026-07-01 Wed +1m>"  (:freq monthly :interval 1))
                  ("<2026-07-01 Wed +1y>"  (:freq yearly  :interval 1))
                  ("<2026-07-01 Wed ++1w>" (:freq weekly  :interval 1))
                  ("<2026-07-01 Wed .+1w>" (:freq weekly  :interval 1))
                  ("<2026-07-01 Wed>"      nil)
                  ("<2026-07-01 Wed +6h>"  nil))) ; sub-day frequency unsupported
    (should (equal (org-apple-calendar--timestamp-recurrence
                    (org-timestamp-from-string (car case)))
                   (cadr case)))))

(ert-deftest org-apple-calendar-test-entry-appointment-recurrence ()
  "`--entry-appointment' carries the repeater as :recurrence."
  (with-temp-buffer
    (let ((org-todo-keywords '((sequence "TODO" "|" "DONE"))))
      (org-mode)
      (insert "* Standup\n  <2026-07-01 Wed 09:00-09:30 +1w>\n")
      (goto-char (point-min))
      (let ((appt (org-apple-calendar--entry-appointment)))
        (should (equal (plist-get appt :recurrence) '(:freq weekly :interval 1)))
        (should-not (plist-get appt :all-day)))))
  (with-temp-buffer
    (org-mode)
    (insert "* One-off\n  <2026-07-01 Wed 09:00>\n")
    (goto-char (point-min))
    (should-not (plist-get (org-apple-calendar--entry-appointment) :recurrence))))

;;; --- create-event injects the recurrence into the JXA script ---------------

(defmacro org-apple-calendar-test--with-captured-script (var &rest body)
  "Run BODY with `--jxa-run' stubbed to bind VAR to the script + return success."
  (declare (indent 1))
  `(let (,var)
     (cl-letf (((symbol-function 'org-apple-calendar--jxa-run)
                (lambda (s)
                  (setq ,var s)
                  "{\"granted\":true,\"result\":{\"ok\":true,\"uid\":\"UID-1\"}}")))
       ,@body)))

(ert-deftest org-apple-calendar-test-create-event-weekly-recurrence ()
  "Weekly/2 recurrence sets rfreq=1, rint=2 and builds an EKRecurrenceRule."
  (org-apple-calendar-test--with-captured-script script
    (let ((res (org-apple-calendar--eventkit-create-event
                "Standup" 1751353200.0 1751355000.0 nil nil
                '(:freq weekly :interval 2))))
      (should (equal (plist-get res :uid) "UID-1"))
      (should (string-match-p "var rfreq=1,rint=2;" script))
      (should (string-match-p
               "initRecurrenceWithFrequencyIntervalEnd(rfreq,rint" script)))))

(ert-deftest org-apple-calendar-test-create-event-no-recurrence ()
  "Without recurrence rfreq is -1 (the rule branch is skipped at runtime)."
  (org-apple-calendar-test--with-captured-script script
    (org-apple-calendar--eventkit-create-event "X" 1.0 2.0 nil nil nil)
    (should (string-match-p "var rfreq=-1,rint=1;" script))))

(ert-deftest org-apple-calendar-test-create-event-monthly-and-yearly ()
  "Monthly/1 and yearly/3 map to rfreq 2 and 3."
  (org-apple-calendar-test--with-captured-script script
    (org-apple-calendar--eventkit-create-event "M" 1.0 2.0 nil nil
                                               '(:freq monthly :interval 1))
    (should (string-match-p "var rfreq=2,rint=1;" script)))
  (org-apple-calendar-test--with-captured-script script
    (org-apple-calendar--eventkit-create-event "Y" 1.0 2.0 nil nil
                                               '(:freq yearly :interval 3))
    (should (string-match-p "var rfreq=3,rint=3;" script))))

;;; --- two-way sync: change detection ----------------------------------------

(ert-deftest org-apple-calendar-test-appointment-differs ()
  "`--appointment-differs-p' compares title, time (60s tolerance), and all-day."
  (let ((appt '(:title "A" :start 1000.0 :end 2000.0 :all-day nil)))
    (cl-flet ((apple (title s e ad)
                (list :title title :start (seconds-to-time s)
                      :end (seconds-to-time e) :all-day ad)))
      (should-not (org-apple-calendar--appointment-differs-p
                   appt (apple "A" 1000.0 2000.0 nil)))
      (should-not (org-apple-calendar--appointment-differs-p
                   appt (apple "A" 1030.0 2000.0 nil)))  ; 30s < tolerance
      (should (org-apple-calendar--appointment-differs-p
               appt (apple "B" 1000.0 2000.0 nil)))      ; title
      (should (org-apple-calendar--appointment-differs-p
               appt (apple "A" 1500.0 2000.0 nil)))      ; start moved
      (should (org-apple-calendar--appointment-differs-p
               appt (apple "A" 1000.0 5000.0 nil)))      ; end moved
      (should (org-apple-calendar--appointment-differs-p
               appt (apple "A" 1000.0 2000.0 t))))))     ; all-day

;;; --- provider API: adoption without reimplementing calendar writes ---------

(defun org-apple-calendar-test--write-file (file text)
  "Write TEXT to FILE, creating parent directories as needed."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert text)))

(defun org-apple-calendar-test--mirror-text ()
  "Return a tiny calendar mirror used by provider API tests."
  "* Dentist
  :PROPERTIES:
  :CALENDAR: Private
  :APPLE_EVENT_UID: dentist-1
  :END:
  <2026-06-20 Sat 09:00-10:00>
")

(ert-deftest org-apple-calendar-test-event-by-uid-reads-mirror ()
  "`org-apple-calendar-event-by-uid' reads the generated mirror only."
  (let* ((root (make-temp-file "oac-provider-" t))
         (mirror (expand-file-name "calendar-mirror.org" root)))
    (org-apple-calendar-test--write-file
     mirror (org-apple-calendar-test--mirror-text))
    (let ((event (org-apple-calendar-event-by-uid "dentist-1" mirror)))
      (should (equal (plist-get event :title) "Dentist"))
      (should (equal (plist-get event :calendar) "Private"))
      (should (equal (plist-get event :uid) "dentist-1"))
      (should-not (plist-get event :all-day)))))

(ert-deftest org-apple-calendar-test-adopt-event-by-uid-uses-package-flow ()
  "`org-apple-calendar-adopt-event-by-uid' owns target write and source ignore."
  (let* ((root (make-temp-file "oac-provider-" t))
         (mirror (expand-file-name "calendar-mirror.org" root))
         (source (expand-file-name "calendar.org" root))
         (overrides (expand-file-name "overrides.eld" root))
         (org-apple-calendar-mirror-file mirror)
         (org-apple-calendar-source-file source)
         (org-apple-calendar-overrides-file overrides)
         (org-apple-calendar-target-calendar "Org")
         (org-apple-calendar-write-backend 'eventkit)
         (org-apple-calendar--overrides 'unset)
         created refresh-called)
    (org-apple-calendar-test--write-file
     mirror (org-apple-calendar-test--mirror-text))
    (org-apple-calendar-test--write-file source "")
    (cl-letf (((symbol-function 'org-apple-calendar--eventkit-create-event)
               (lambda (&rest args)
                 (setq created args)
                 '(:uid "org-event-1" :mod 123)))
              ((symbol-function 'org-apple-calendar-refresh-mirror)
               (lambda (&optional _days)
                 (setq refresh-called t)
                 0)))
      (let ((result (org-apple-calendar-adopt-event-by-uid "dentist-1" mirror)))
        (should (equal (plist-get result :kind) 'org-apple-calendar-adoption))
        (should (equal (plist-get result :source-uid) "dentist-1"))
        (should (plist-get result :source-ignored))
        (should (equal (plist-get result :target-apple-event-id) "org-event-1"))
        (should (equal (plist-get result :target-file) source))
        (should created)
        (should refresh-called)
        (with-temp-buffer
          (insert-file-contents source)
          (should (search-forward ":ADOPTED_FROM_UID: dentist-1" nil t))
          (should (search-forward ":APPLE_EVENT_ID: org-event-1" nil t))
          (should (search-forward ":APPLE_CALENDAR: Org" nil t)))
        (with-temp-buffer
          (insert-file-contents overrides)
          (should (equal (read (current-buffer)) '(("dentist-1" . ignore)))))))))

(ert-deftest org-apple-calendar-test-create-appointment-uses-package-flow ()
  "`org-apple-calendar-create-appointment' owns EventKit and calendar.org writes."
  (let* ((root (make-temp-file "oac-create-" t))
         (source (expand-file-name "calendar.org" root))
         (org-apple-calendar-source-file source)
         (org-apple-calendar-target-calendar "Org")
         (org-apple-calendar-write-backend 'eventkit)
         created refresh-called)
    (org-apple-calendar-test--write-file source "#+TITLE: Calendar\n")
    (cl-letf (((symbol-function 'org-apple-calendar--eventkit-create-event)
               (lambda (&rest args)
                 (setq created args)
                 '(:uid "created-1" :mod 456)))
              ((symbol-function 'org-apple-calendar-refresh-mirror)
               (lambda (&optional _days)
                 (setq refresh-called t)
                 1)))
      (let ((result (org-apple-calendar-create-appointment
                     "Focus block"
                     "2026-06-22 09:00"
                     "2026-06-22 10:30"
                     nil
                     "Deep work"
                     nil
                     t)))
        (should (equal (plist-get result :kind)
                       'org-apple-calendar-created-appointment))
        (should (equal (plist-get result :target-apple-event-id)
                       "created-1"))
        (should refresh-called)
        (should (equal (nth 0 created) "Focus block"))
        (should (equal (nth 4 created) "Deep work"))
        (with-temp-buffer
          (insert-file-contents source)
          (should (search-forward "* Focus block" nil t))
          (should (search-forward ":APPLE_EVENT_ID: created-1" nil t))
          (should (search-forward ":APPLE_CALENDAR: Org" nil t))
          (should (search-forward ":APPLE_MOD: 456" nil t))
          (should (search-forward "<2026-06-22 Mon 09:00-10:30>" nil t))
          (should (search-forward "Deep work" nil t)))))))

(ert-deftest org-apple-calendar-test-create-appointment-weekly-recurrence ()
  "`org-apple-calendar-create-appointment' records simple recurrence in Org."
  (let* ((root (make-temp-file "oac-create-recur-" t))
         (source (expand-file-name "calendar.org" root))
         (org-apple-calendar-source-file source)
         (org-apple-calendar-target-calendar "Org")
         (org-apple-calendar-write-backend 'eventkit)
         created)
    (org-apple-calendar-test--write-file source "")
    (cl-letf (((symbol-function 'org-apple-calendar--eventkit-create-event)
               (lambda (&rest args)
                 (setq created args)
                 '(:uid "weekly-1" :mod 789))))
      (org-apple-calendar-create-appointment
       "Weekly planning"
       "2026-06-22 08:00"
       "2026-06-22 08:30"
       nil nil '(:freq weekly :interval 1))
      (should (equal (nth 5 created) '(:freq weekly :interval 1)))
      (with-temp-buffer
        (insert-file-contents source)
        (should (search-forward
                 "<2026-06-22 Mon 08:00-08:30 +1w>" nil t))))))

(provide 'org-apple-calendar-tests)
;;; org-apple-calendar-tests.el ends here
