;; Peer-to-Peer Lending System
;; Decentralized lending platform connecting borrowers and lenders
;; Match lenders with borrowers, manage loan terms, and automate repayments

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-LOAN-NOT-FOUND (err u101))
(define-constant ERR-LOAN-EXISTS (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-LOAN-ALREADY-FUNDED (err u104))
(define-constant ERR-PAYMENT-FAILED (err u105))
(define-constant ERR-LOAN-DEFAULTED (err u106))
(define-constant ERR-INVALID-PARAMETERS (err u107))
(define-constant ERR-NOT-BORROWER (err u108))
(define-constant ERR-NOT-LENDER (err u109))

;; Loan status constants
(define-constant STATUS-REQUESTED u1)
(define-constant STATUS-FUNDED u2)
(define-constant STATUS-ACTIVE u3)
(define-constant STATUS-REPAID u4)
(define-constant STATUS-DEFAULTED u5)

;; Credit score ranges
(define-constant CREDIT-EXCELLENT u800)
(define-constant CREDIT-GOOD u740)
(define-constant CREDIT-FAIR u670)
(define-constant CREDIT-POOR u580)

;; data maps and vars
;; Main loan registry
(define-map loans
  { loan-id: (string-ascii 64) }
  {
    borrower: principal,
    lender: (optional principal),
    amount: uint,
    interest-rate: uint, ;; Basis points (800 = 8%)
    term-months: uint,
    monthly-payment: uint,
    total-repayment: uint,
    amount-paid: uint,
    payments-made: uint,
    status: uint,
    creation-date: uint,
    funding-date: (optional uint),
    next-payment-due: (optional uint),
    purpose: (string-ascii 256),
    credit-score: uint,
    collateral-amount: uint,
    late-payments: uint
  }
)

;; User credit profiles
(define-map user-profiles
  { user: principal }
  {
    credit-score: uint,
    total-borrowed: uint,
    total-lent: uint,
    active-loans: uint,
    completed-loans: uint,
    default-count: uint,
    last-updated: uint,
    reputation-score: uint,
    verification-status: bool
  }
)

;; Payment history tracking
(define-map payment-history
  { loan-id: (string-ascii 64), payment-index: uint }
  {
    amount: uint,
    date: uint,
    principal-portion: uint,
    interest-portion: uint,
    late-fee: uint,
    days-late: uint
  }
)

;; Lender investment portfolios
(define-map lender-portfolios
  { lender: principal, loan-id: (string-ascii 64) }
  {
    invested-amount: uint,
    interest-earned: uint,
    investment-date: uint,
    expected-return: uint,
    risk-level: uint
  }
)

;; Platform statistics
(define-data-var total-loans uint u0)
(define-data-var total-volume uint u0)
(define-data-var total-interest-paid uint u0)
(define-data-var platform-fees-collected uint u0)
(define-data-var next-loan-id uint u1)

;; Fee structure
(define-data-var origination-fee-rate uint u300) ;; 3%
(define-data-var service-fee-rate uint u100) ;; 1% annually
(define-data-var late-fee-amount uint u25000000) ;; 25 STX

;; private functions
;; Calculate monthly payment using interest rate and term
(define-private (calculate-monthly-payment 
    (principal uint)
    (annual-rate uint) ;; In basis points
    (term-months uint))
  (let (
    (monthly-rate (/ annual-rate u1200)) ;; Convert to monthly decimal
    (rate-factor (+ u1000000 monthly-rate)) ;; 1 + monthly rate (scaled)
    (denominator (- (pow rate-factor term-months) u1000000))
  )
    (if (is-eq monthly-rate u0)
        (/ principal term-months)
        (/ (* (* principal monthly-rate) (pow rate-factor term-months)) denominator)
    )
  )
)

;; Calculate credit score based on multiple factors
(define-private (calculate-credit-score (user principal))
  (match (map-get? user-profiles {user: user})
    profile
    (let (
      (base-score u650)
      (payment-history-bonus (* (- (get completed-loans profile) (get default-count profile)) u20))
      (volume-bonus (if (> (get total-borrowed profile) u100000000) u50 u0))
      (reputation-bonus (get reputation-score profile))
      (penalty (* (get default-count profile) u100))
    )
      (if (<= (+ base-score payment-history-bonus volume-bonus reputation-bonus) penalty)
          u300
          (- (+ base-score payment-history-bonus volume-bonus reputation-bonus) penalty)
      )
    )
    u650 ;; Default score for new users
  )
)

;; Determine interest rate based on credit score
(define-private (get-interest-rate-for-score (credit-score uint))
  (if (>= credit-score CREDIT-EXCELLENT)
      u500  ;; 5%
      (if (>= credit-score CREDIT-GOOD)
          u700  ;; 7%
          (if (>= credit-score CREDIT-FAIR)
              u1000 ;; 10%
              (if (>= credit-score CREDIT-POOR)
                  u1500 ;; 15%
                  u2000 ;; 20%
              )
          )
      )
  )
)

;; Update user profile statistics
(define-private (update-user-profile 
    (user principal)
    (amount uint)
    (is-borrower bool)
    (is-completion bool))
  (let (
    (current-profile (default-to 
      {
        credit-score: u650,
        total-borrowed: u0,
        total-lent: u0,
        active-loans: u0,
        completed-loans: u0,
        default-count: u0,
        last-updated: stacks-block-height,
        reputation-score: u50,
        verification-status: false
      }
      (map-get? user-profiles {user: user})
    ))
  )
    (map-set user-profiles
      {user: user}
      (merge current-profile {
        total-borrowed: (if is-borrower 
                          (+ (get total-borrowed current-profile) amount)
                          (get total-borrowed current-profile)),
        total-lent: (if (not is-borrower)
                       (+ (get total-lent current-profile) amount)
                       (get total-lent current-profile)),
        active-loans: (if is-completion
                        (- (get active-loans current-profile) u1)
                        (+ (get active-loans current-profile) u1)),
        completed-loans: (if is-completion
                           (+ (get completed-loans current-profile) u1)
                           (get completed-loans current-profile)),
        last-updated: stacks-block-height,
        credit-score: (calculate-credit-score user)
      })
    )
  )
)

;; Validate loan parameters
(define-private (is-valid-loan-request 
    (amount uint)
    (term-months uint)
    (interest-rate uint))
  (and
    (>= amount u1000000) ;; Minimum 1 STX
    (<= amount u1000000000000) ;; Maximum 1M STX
    (>= term-months u1)
    (<= term-months u60)
    (>= interest-rate u100) ;; Minimum 1%
    (<= interest-rate u3000) ;; Maximum 30%
  )
)

;; public functions
;; Create a new loan request
(define-public (create-loan-request
    (loan-id (string-ascii 64))
    (amount uint)
    (term-months uint)
    (requested-rate uint)
    (purpose (string-ascii 256)))
  (let (
    (borrower tx-sender)
    (credit-score (calculate-credit-score borrower))
    (suggested-rate (get-interest-rate-for-score credit-score))
    (final-rate (if (> requested-rate suggested-rate) suggested-rate requested-rate))
    (monthly-payment (calculate-monthly-payment amount final-rate term-months))
    (total-repayment (* monthly-payment term-months))
  )
    (asserts! (is-valid-loan-request amount term-months requested-rate) ERR-INVALID-PARAMETERS)
    (asserts! (is-none (map-get? loans {loan-id: loan-id})) ERR-LOAN-EXISTS)
    
    (map-set loans
      {loan-id: loan-id}
      {
        borrower: borrower,
        lender: none,
        amount: amount,
        interest-rate: final-rate,
        term-months: term-months,
        monthly-payment: monthly-payment,
        total-repayment: total-repayment,
        amount-paid: u0,
        payments-made: u0,
        status: STATUS-REQUESTED,
        creation-date: stacks-block-height,
        funding-date: none,
        next-payment-due: none,
        purpose: purpose,
        credit-score: credit-score,
        collateral-amount: u0,
        late-payments: u0
      }
    )
    
    (var-set total-loans (+ (var-get total-loans) u1))
    (var-set next-loan-id (+ (var-get next-loan-id) u1))
    (ok loan-id)
  )
)

;; Fund a loan request
(define-public (fund-loan (loan-id (string-ascii 64)))
  (let (
    (lender tx-sender)
  )
    (match (map-get? loans {loan-id: loan-id})
      loan
      (begin
        (asserts! (is-eq (get status loan) STATUS-REQUESTED) ERR-LOAN-ALREADY-FUNDED)
        (asserts! (>= (stx-get-balance lender) (get amount loan)) ERR-INSUFFICIENT-FUNDS)
        
        ;; Transfer funds to borrower
        (try! (stx-transfer? (get amount loan) lender (get borrower loan)))
        
        ;; Calculate origination fee and collect it
        (let (
          (origination-fee (/ (* (get amount loan) (var-get origination-fee-rate)) u10000))
          (next-payment-date (+ stacks-block-height u144)) ;; ~1 month (144 blocks)
        )
          (try! (stx-transfer? origination-fee (get borrower loan) CONTRACT-OWNER))
          (var-set platform-fees-collected (+ (var-get platform-fees-collected) origination-fee))
          
          ;; Update loan status
          (map-set loans
            {loan-id: loan-id}
            (merge loan {
              lender: (some lender),
              status: STATUS-ACTIVE,
              funding-date: (some stacks-block-height),
              next-payment-due: (some next-payment-date)
            })
          )
          
          ;; Record lender investment
          (map-set lender-portfolios
            {lender: lender, loan-id: loan-id}
            {
              invested-amount: (get amount loan),
              interest-earned: u0,
              investment-date: stacks-block-height,
              expected-return: (- (get total-repayment loan) (get amount loan)),
              risk-level: (- u1000 (/ (get credit-score loan) u1))
            }
          )
          
          ;; Update user profiles
          (update-user-profile (get borrower loan) (get amount loan) true false)
          (update-user-profile lender (get amount loan) false false)
          
          (var-set total-volume (+ (var-get total-volume) (get amount loan)))
          (ok true)
        )
      )
      ERR-LOAN-NOT-FOUND
    )
  )
)

;; Make a loan payment
(define-public (make-payment (loan-id (string-ascii 64)) (payment-amount uint))
  (let (
    (payer tx-sender)
  )
    (match (map-get? loans {loan-id: loan-id})
      loan
      (begin
        (asserts! (is-eq payer (get borrower loan)) ERR-NOT-BORROWER)
        (asserts! (is-eq (get status loan) STATUS-ACTIVE) ERR-LOAN-NOT-FOUND)
        (asserts! (>= (stx-get-balance payer) payment-amount) ERR-INSUFFICIENT-FUNDS)
        
        (match (get lender loan)
          lender-addr
          (let (
            (monthly-payment (get monthly-payment loan))
            (is-late (match (get next-payment-due loan)
              due-date (> stacks-block-height due-date)
              false))
            (late-fee (if is-late (var-get late-fee-amount) u0))
            (total-payment (+ payment-amount late-fee))
            (interest-portion (/ (* payment-amount (get interest-rate loan)) u1200))
            (principal-portion (- payment-amount interest-portion))
            (new-amount-paid (+ (get amount-paid loan) payment-amount))
            (new-payments-made (+ (get payments-made loan) u1))
            (payment-index (get payments-made loan))
          )
            ;; Transfer payment to lender
            (try! (stx-transfer? payment-amount payer lender-addr))
            
            ;; Collect late fee if applicable
            (if is-late
                (begin
                  (try! (stx-transfer? late-fee payer CONTRACT-OWNER))
                  (var-set platform-fees-collected (+ (var-get platform-fees-collected) late-fee))
                )
                true
            )
            
            ;; Record payment history
            (map-set payment-history
              {loan-id: loan-id, payment-index: payment-index}
              {
                amount: payment-amount,
                date: stacks-block-height,
                principal-portion: principal-portion,
                interest-portion: interest-portion,
                late-fee: late-fee,
                days-late: (if is-late u30 u0)
              }
            )
            
            ;; Update lender portfolio
            (match (map-get? lender-portfolios {lender: lender-addr, loan-id: loan-id})
              portfolio
              (map-set lender-portfolios
                {lender: lender-addr, loan-id: loan-id}
                (merge portfolio {
                  interest-earned: (+ (get interest-earned portfolio) interest-portion)
                })
              )
              false
            )
            
            ;; Update loan status
            (let (
              (is-fully-paid (>= new-amount-paid (get total-repayment loan)))
              (new-status (if is-fully-paid STATUS-REPAID STATUS-ACTIVE))
              (next-due (if is-fully-paid 
                           none 
                           (some (+ stacks-block-height u144))))
            )
              (map-set loans
                {loan-id: loan-id}
                (merge loan {
                  amount-paid: new-amount-paid,
                  payments-made: new-payments-made,
                  status: new-status,
                  next-payment-due: next-due,
                  late-payments: (if is-late 
                                   (+ (get late-payments loan) u1)
                                   (get late-payments loan))
                })
              )
              
              ;; Update user profiles if loan is completed
              (if is-fully-paid
                  (begin
                    (update-user-profile (get borrower loan) u0 true true)
                    (update-user-profile lender-addr u0 false true)
                  )
                  true
              )
              
              (var-set total-interest-paid (+ (var-get total-interest-paid) interest-portion))
              (ok true)
            )
          )
          ERR-LOAN-NOT-FOUND
        )
      )
      ERR-LOAN-NOT-FOUND
    )
  )
)

;; Get loan information
(define-public (get-loan-info (loan-id (string-ascii 64)))
  (ok (map-get? loans {loan-id: loan-id}))
)

;; Get user credit profile
(define-public (get-user-profile (user principal))
  (ok (map-get? user-profiles {user: user}))
)

;; Get lender portfolio
(define-public (get-lender-portfolio (lender principal) (loan-id (string-ascii 64)))
  (ok (map-get? lender-portfolios {lender: lender, loan-id: loan-id}))
)

;; Calculate and return current credit score
(define-public (calculate-user-credit-score (user principal))
  (ok (calculate-credit-score user))
)

;; Get payment history
(define-public (get-payment-info (loan-id (string-ascii 64)) (payment-index uint))
  (ok (map-get? payment-history {loan-id: loan-id, payment-index: payment-index}))
)

;; read only functions
;; Get platform statistics
(define-read-only (get-platform-stats)
  {
    total-loans: (var-get total-loans),
    total-volume: (var-get total-volume),
    total-interest-paid: (var-get total-interest-paid),
    platform-fees-collected: (var-get platform-fees-collected)
  }
)

;; Get current fee rates
(define-read-only (get-fee-rates)
  {
    origination-fee-rate: (var-get origination-fee-rate),
    service-fee-rate: (var-get service-fee-rate),
    late-fee-amount: (var-get late-fee-amount)
  }
)

;; Get suggested interest rate for credit score
(define-read-only (get-suggested-rate (credit-score uint))
  (get-interest-rate-for-score credit-score)
)

;; Check if loan is overdue
(define-read-only (is-loan-overdue (loan-id (string-ascii 64)))
  (match (map-get? loans {loan-id: loan-id})
    loan
    (match (get next-payment-due loan)
      due-date (> stacks-block-height due-date)
      false)
    false
  )
)
