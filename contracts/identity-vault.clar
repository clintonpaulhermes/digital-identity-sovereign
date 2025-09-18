;; identity-vault
;; Self-Sovereign Identity Smart Contract
;; Stores encrypted identity credentials with user-controlled access permissions
;; and selective disclosure capabilities. Manages identity attestations from trusted
;; verifiers with reputation weighting and fraud detection mechanisms.

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_IDENTITY_NOT_FOUND (err u101))
(define-constant ERR_CREDENTIAL_NOT_FOUND (err u102))
(define-constant ERR_ALREADY_EXISTS (err u103))
(define-constant ERR_INVALID_PARAMETERS (err u104))
(define-constant ERR_EXPIRED_CREDENTIAL (err u105))
(define-constant ERR_REVOKED_CREDENTIAL (err u106))
(define-constant ERR_INSUFFICIENT_REPUTATION (err u107))
(define-constant ERR_INVALID_PROOF (err u108))
(define-constant ERR_RECOVERY_LOCKED (err u109))
(define-constant ERR_GUARDIAN_NOT_FOUND (err u110))
(define-constant ERR_INVALID_SIGNATURE (err u111))

;; Contract parameters
(define-constant MINIMUM_ISSUER_REPUTATION u70)
(define-constant CREDENTIAL_MAX_VALIDITY u525600) ;; ~10 years in blocks
(define-constant RECOVERY_LOCK_PERIOD u1440) ;; ~1 day in blocks
(define-constant GUARDIAN_THRESHOLD u3) ;; Minimum guardians for recovery
(define-constant REPUTATION_DECAY_RATE u1) ;; Reputation decay per period
(define-constant ZK_PROOF_VALIDITY u144) ;; ~1 day validity for proofs

;; Data Variables
(define-data-var identity-counter uint u0)
(define-data-var credential-counter uint u0)
(define-data-var verifier-counter uint u0)
(define-data-var recovery-request-counter uint u0)
(define-data-var oauth-bridge-counter uint u0)
(define-data-var total-identities uint u0)
(define-data-var total-credentials uint u0)
(define-data-var global-reputation-pool uint u0)

;; Data Maps

;; Core identity registry with cryptographic security
(define-map identities
  { identity-id: principal }
  {
    public-key: (buff 33),
    recovery-hash: (buff 32),
    credential-count: uint,
    reputation-score: uint,
    created-at: uint,
    last-updated: uint,
    last-activity: uint,
    is-active: bool,
    privacy-settings: uint,
    recovery-lock-until: uint
  }
)

;; Credential storage with encryption and metadata
(define-map credentials
  { credential-id: uint }
  {
    owner: principal,
    issuer: principal,
    credential-type: (string-ascii 64),
    encrypted-data: (buff 512),
    proof-hash: (buff 32),
    metadata-hash: (buff 32),
    issued-at: uint,
    expires-at: uint,
    last-verified: uint,
    verification-count: uint,
    is-revoked: bool,
    revocation-reason: (string-ascii 128)
  }
)

;; Trusted verifier registry with reputation tracking
(define-map verifiers
  { verifier-id: principal }
  {
    name: (string-ascii 256),
    verification-types: (list 10 (string-ascii 64)),
    reputation-score: uint,
    total-verifications: uint,
    successful-verifications: uint,
    registration-date: uint,
    last-audit: uint,
    is-active: bool,
    stake-amount: uint
  }
)

;; Zero-knowledge proof records
(define-map zk-proofs
  { proof-id: uint }
  {
    prover: principal,
    verifier: principal,
    credential-id: uint,
    proof-type: (string-ascii 64),
    proof-hash: (buff 32),
    challenge-hash: (buff 32),
    created-at: uint,
    expires-at: uint,
    is-verified: bool,
    verification-result: (string-ascii 128)
  }
)

;; Social recovery system
(define-map recovery-guardians
  { identity: principal, guardian: principal }
  {
    guardian-type: (string-ascii 32), ;; "social", "institutional", "device"
    added-at: uint,
    last-verified: uint,
    trust-score: uint,
    recovery-weight: uint,
    is-active: bool
  }
)

;; Recovery requests tracking
(define-map recovery-requests
  { request-id: uint }
  {
    identity: principal,
    requester: principal,
    new-recovery-hash: (buff 32),
    guardian-approvals: (list 10 principal),
    approval-count: uint,
    created-at: uint,
    expires-at: uint,
    is-executed: bool,
    execution-block: uint
  }
)

;; Access permissions for selective disclosure
(define-map access-permissions
  { identity: principal, accessor: principal }
  {
    permission-types: (list 10 (string-ascii 64)),
    granted-at: uint,
    expires-at: uint,
    usage-count: uint,
    max-usage: uint,
    is-active: bool
  }
)

;; Privacy-preserving analytics (anonymized)
(define-map analytics-data
  { metric-type: (string-ascii 64) }
  {
    total-count: uint,
    daily-count: uint,
    last-updated: uint,
    trend-direction: (string-ascii 16)
  }
)

;; Interoperability bridges for Web2 integration
(define-map oauth-bridges
  { bridge-id: uint }
  {
    identity: principal,
    provider: (string-ascii 128),
    client-id-hash: (buff 32),
    scope-permissions: (list 10 (string-ascii 64)),
    created-at: uint,
    last-used: uint,
    is-active: bool
  }
)

;; Private Functions

;; Calculate reputation score based on activity and verifications
(define-private (calculate-reputation 
  (identity-data (tuple 
    (public-key (buff 33))
    (recovery-hash (buff 32))
    (credential-count uint)
    (reputation-score uint)
    (created-at uint)
    (last-updated uint)
    (last-activity uint)
    (is-active bool)
    (privacy-settings uint)
    (recovery-lock-until uint))))
  (let (
    (base-score (get reputation-score identity-data))
    (activity-bonus (if (< (- burn-block-height (get last-activity identity-data)) u1440) u5 u0))
    (credential-bonus (if (<= (/ (get credential-count identity-data) u10) u10)
                          (/ (get credential-count identity-data) u10)
                          u10))
    (time-decay (/ (- burn-block-height (get last-activity identity-data)) u4320)) ;; monthly decay
  )
    (+ base-score activity-bonus credential-bonus (if (> time-decay u10) u0 (- u10 time-decay)))
  )
)

;; Validate zero-knowledge proof structure
(define-private (validate-zk-proof (proof-hash (buff 32)) (challenge-hash (buff 32)) (credential-id uint))
  (match (map-get? credentials { credential-id: credential-id })
    credential-data
    (let (
      (expected-hash (sha256 (concat (get proof-hash credential-data) challenge-hash)))
    )
      (is-eq proof-hash expected-hash)
    )
    false
  )
)

;; Check if credential is valid and not expired/revoked
(define-private (is-credential-valid (credential-id uint))
  (match (map-get? credentials { credential-id: credential-id })
    credential-data
    (and 
      (not (get is-revoked credential-data))
      (> (get expires-at credential-data) burn-block-height)
    )
    false
  )
)

;; Verify issuer reputation meets requirements
(define-private (is-issuer-trusted (issuer principal))
  (match (map-get? verifiers { verifier-id: issuer })
    verifier-data
    (and 
      (get is-active verifier-data)
      (>= (get reputation-score verifier-data) MINIMUM_ISSUER_REPUTATION)
    )
    false
  )
)

;; Calculate guardian consensus for recovery
(define-private (calculate-guardian-consensus (approvals (list 10 principal)) (identity principal))
  (let (
    (total-weight (fold sum-guardian-weight approvals u0))
    (required-weight (* GUARDIAN_THRESHOLD u10)) ;; Each guardian has weight 10
  )
    (>= total-weight required-weight)
  )
)

(define-private (sum-guardian-weight (guardian principal) (acc uint))
  (match (map-get? recovery-guardians { identity: tx-sender, guardian: guardian })
    guardian-data (+ acc (get recovery-weight guardian-data))
    acc
  )
)

;; Update privacy-preserving analytics
(define-private (update-analytics (metric-type (string-ascii 64)))
  (let (
    (current-data (default-to 
                     { total-count: u0, daily-count: u0, last-updated: u0, trend-direction: "up" }
                     (map-get? analytics-data { metric-type: metric-type })))
  )
    (map-set analytics-data { metric-type: metric-type }
             (merge current-data {
               total-count: (+ (get total-count current-data) u1),
               daily-count: (if (is-eq (get last-updated current-data) burn-block-height) 
                               (+ (get daily-count current-data) u1) u1),
               last-updated: burn-block-height
             }))
  )
)

;; Public Functions

;; Create a new self-sovereign identity
(define-public (create-identity (public-key (buff 33)) (recovery-hash (buff 32)))
  (begin
    (asserts! (is-none (map-get? identities { identity-id: tx-sender })) ERR_ALREADY_EXISTS)
    (asserts! (> (len public-key) u0) ERR_INVALID_PARAMETERS)
    (asserts! (> (len recovery-hash) u0) ERR_INVALID_PARAMETERS)
    
    (map-set identities { identity-id: tx-sender }
             {
               public-key: public-key,
               recovery-hash: recovery-hash,
               credential-count: u0,
               reputation-score: u50, ;; Starting reputation
               created-at: burn-block-height,
               last-updated: burn-block-height,
               last-activity: burn-block-height,
               is-active: true,
               privacy-settings: u7, ;; Default privacy level
               recovery-lock-until: u0
             })
    
    (var-set total-identities (+ (var-get total-identities) u1))
    (update-analytics "identity-created")
    (ok tx-sender)
  )
)

;; Register as a trusted credential verifier
(define-public (register-verifier 
                 (name (string-ascii 256))
                 (verification-types (list 10 (string-ascii 64)))
                 (stake-amount uint))
  (begin
    (asserts! (is-none (map-get? verifiers { verifier-id: tx-sender })) ERR_ALREADY_EXISTS)
    (asserts! (> (len name) u0) ERR_INVALID_PARAMETERS)
    (asserts! (>= stake-amount u1000) ERR_INVALID_PARAMETERS) ;; Minimum stake
    
    (map-set verifiers { verifier-id: tx-sender }
             {
               name: name,
               verification-types: verification-types,
               reputation-score: u75, ;; Starting verifier reputation
               total-verifications: u0,
               successful-verifications: u0,
               registration-date: burn-block-height,
               last-audit: burn-block-height,
               is-active: true,
               stake-amount: stake-amount
             })
    
    (var-set verifier-counter (+ (var-get verifier-counter) u1))
    (ok tx-sender)
  )
)

;; Issue a verifiable credential
(define-public (issue-credential
                 (recipient principal)
                 (credential-type (string-ascii 64))
                 (encrypted-data (buff 512))
                 (proof-hash (buff 32))
                 (expires-at uint))
  (let (
    (credential-id (+ (var-get credential-counter) u1))
    (recipient-data (unwrap! (map-get? identities { identity-id: recipient }) ERR_IDENTITY_NOT_FOUND))
    (metadata-hash (sha256 (concat (concat (unwrap-panic (to-consensus-buff? credential-type)) 
                                          (unwrap-panic (to-consensus-buff? recipient)))
                                  (unwrap-panic (to-consensus-buff? burn-block-height)))))
  )
    (asserts! (is-issuer-trusted tx-sender) ERR_INSUFFICIENT_REPUTATION)
    (asserts! (> expires-at burn-block-height) ERR_INVALID_PARAMETERS)
    (asserts! (<= expires-at (+ burn-block-height CREDENTIAL_MAX_VALIDITY)) ERR_INVALID_PARAMETERS)
    
    (map-set credentials { credential-id: credential-id }
             {
               owner: recipient,
               issuer: tx-sender,
               credential-type: credential-type,
               encrypted-data: encrypted-data,
               proof-hash: proof-hash,
               metadata-hash: metadata-hash,
               issued-at: burn-block-height,
               expires-at: expires-at,
               last-verified: u0,
               verification-count: u0,
               is-revoked: false,
               revocation-reason: ""
             })
    
    ;; Update recipient's credential count
    (map-set identities { identity-id: recipient }
             (merge recipient-data { 
               credential-count: (+ (get credential-count recipient-data) u1),
               last-updated: burn-block-height
             }))
    
    ;; Update issuer statistics
    (let (
      (verifier-data (unwrap-panic (map-get? verifiers { verifier-id: tx-sender })))
    )
      (map-set verifiers { verifier-id: tx-sender }
               (merge verifier-data { 
                 total-verifications: (+ (get total-verifications verifier-data) u1)
               }))
    )
    
    (var-set credential-counter credential-id)
    (var-set total-credentials (+ (var-get total-credentials) u1))
    (update-analytics "credential-issued")
    (ok credential-id)
  )
)

;; Verify credential using zero-knowledge proof
(define-public (verify-credential
                 (credential-id uint)
                 (proof-hash (buff 32))
                 (proof-type (string-ascii 64)))
  (let (
    (credential-data (unwrap! (map-get? credentials { credential-id: credential-id }) ERR_CREDENTIAL_NOT_FOUND))
    (challenge-hash (sha256 (concat proof-hash (unwrap-panic (to-consensus-buff? burn-block-height)))))
  )
    (asserts! (is-credential-valid credential-id) ERR_EXPIRED_CREDENTIAL)
    (asserts! (validate-zk-proof proof-hash challenge-hash credential-id) ERR_INVALID_PROOF)
    
    ;; Update credential verification statistics
    (map-set credentials { credential-id: credential-id }
             (merge credential-data {
               last-verified: burn-block-height,
               verification-count: (+ (get verification-count credential-data) u1)
             }))
    
    ;; Update owner's last activity
    (let (
      (owner-data (unwrap-panic (map-get? identities { identity-id: (get owner credential-data) })))
    )
      (map-set identities { identity-id: (get owner credential-data) }
               (merge owner-data { last-activity: burn-block-height }))
    )
    
    (update-analytics "credential-verified")
    (ok {
      verified: true,
      credential-type: (get credential-type credential-data),
      issued-at: (get issued-at credential-data),
      issuer: (get issuer credential-data),
      proof-type: proof-type
    })
  )
)

;; Add guardian for social recovery
(define-public (add-recovery-guardian
                 (guardian principal)
                 (guardian-type (string-ascii 32))
                 (trust-score uint)
                 (recovery-weight uint))
  (let (
    (identity-data (unwrap! (map-get? identities { identity-id: tx-sender }) ERR_IDENTITY_NOT_FOUND))
  )
    (asserts! (is-none (map-get? recovery-guardians { identity: tx-sender, guardian: guardian })) ERR_ALREADY_EXISTS)
    (asserts! (<= trust-score u100) ERR_INVALID_PARAMETERS)
    (asserts! (<= recovery-weight u20) ERR_INVALID_PARAMETERS)
    
    (map-set recovery-guardians { identity: tx-sender, guardian: guardian }
             {
               guardian-type: guardian-type,
               added-at: burn-block-height,
               last-verified: burn-block-height,
               trust-score: trust-score,
               recovery-weight: recovery-weight,
               is-active: true
             })
    
    (ok guardian)
  )
)

;; Initiate identity recovery process
(define-public (initiate-recovery
                 (identity principal)
                 (new-recovery-hash (buff 32)))
  (let (
    (identity-data (unwrap! (map-get? identities { identity-id: identity }) ERR_IDENTITY_NOT_FOUND))
    (request-id (+ (var-get recovery-request-counter) u1))
  )
    (asserts! (> burn-block-height (get recovery-lock-until identity-data)) ERR_RECOVERY_LOCKED)
    (asserts! (> (len new-recovery-hash) u0) ERR_INVALID_PARAMETERS)
    
    (map-set recovery-requests { request-id: request-id }
             {
               identity: identity,
               requester: tx-sender,
               new-recovery-hash: new-recovery-hash,
               guardian-approvals: (list),
               approval-count: u0,
               created-at: burn-block-height,
               expires-at: (+ burn-block-height RECOVERY_LOCK_PERIOD),
               is-executed: false,
               execution-block: u0
             })
    
    (var-set recovery-request-counter request-id)
    (ok request-id)
  )
)

;; Guardian approval for recovery request
(define-public (approve-recovery (request-id uint))
  (let (
    (request-data (unwrap! (map-get? recovery-requests { request-id: request-id }) ERR_CREDENTIAL_NOT_FOUND))
    (guardian-data (unwrap! (map-get? recovery-guardians 
                                   { identity: (get identity request-data), guardian: tx-sender }) ERR_GUARDIAN_NOT_FOUND))
    (updated-approvals (unwrap! (as-max-len? (append (get guardian-approvals request-data) tx-sender) u10) ERR_INVALID_PARAMETERS))
  )
    (asserts! (get is-active guardian-data) ERR_NOT_AUTHORIZED)
    (asserts! (> (get expires-at request-data) burn-block-height) ERR_EXPIRED_CREDENTIAL)
    (asserts! (not (get is-executed request-data)) ERR_ALREADY_EXISTS)
    
    (map-set recovery-requests { request-id: request-id }
             (merge request-data {
               guardian-approvals: updated-approvals,
               approval-count: (+ (get approval-count request-data) u1)
             }))
    
    ;; Check if consensus reached and execute recovery
    (if (calculate-guardian-consensus updated-approvals (get identity request-data))
        (begin
          (let (
            (identity-data (unwrap-panic (map-get? identities { identity-id: (get identity request-data) })))
          )
            (map-set identities { identity-id: (get identity request-data) }
                     (merge identity-data { 
                       recovery-hash: (get new-recovery-hash request-data),
                       last-updated: burn-block-height,
                       recovery-lock-until: (+ burn-block-height RECOVERY_LOCK_PERIOD)
                     }))
            
            (map-set recovery-requests { request-id: request-id }
                     (merge request-data {
                       is-executed: true,
                       execution-block: burn-block-height
                     }))
          )
          (ok "RECOVERY_EXECUTED")
        )
        (ok "APPROVAL_RECORDED")
    )
  )
)

;; Grant selective access permissions
(define-public (grant-access
                 (accessor principal)
                 (permission-types (list 10 (string-ascii 64)))
                 (expires-at uint)
                 (max-usage uint))
  (begin
    (asserts! (is-some (map-get? identities { identity-id: tx-sender })) ERR_IDENTITY_NOT_FOUND)
    (asserts! (> expires-at burn-block-height) ERR_INVALID_PARAMETERS)
    
    (map-set access-permissions { identity: tx-sender, accessor: accessor }
             {
               permission-types: permission-types,
               granted-at: burn-block-height,
               expires-at: expires-at,
               usage-count: u0,
               max-usage: max-usage,
               is-active: true
             })
    
    (ok accessor)
  )
)

;; Revoke credential
(define-public (revoke-credential (credential-id uint) (reason (string-ascii 128)))
  (let (
    (credential-data (unwrap! (map-get? credentials { credential-id: credential-id }) ERR_CREDENTIAL_NOT_FOUND))
  )
    (asserts! (or (is-eq tx-sender (get owner credential-data)) 
                  (is-eq tx-sender (get issuer credential-data))) ERR_NOT_AUTHORIZED)
    
    (map-set credentials { credential-id: credential-id }
             (merge credential-data {
               is-revoked: true,
               revocation-reason: reason
             }))
    
    (update-analytics "credential-revoked")
    (ok credential-id)
  )
)

;; Create OAuth bridge for Web2 integration
(define-public (create-oauth-bridge
                 (provider (string-ascii 128))
                 (client-id-hash (buff 32))
                 (scope-permissions (list 10 (string-ascii 64))))
  (let (
    (bridge-id (+ (var-get oauth-bridge-counter) u1))
  )
    (asserts! (is-some (map-get? identities { identity-id: tx-sender })) ERR_IDENTITY_NOT_FOUND)
    
    (map-set oauth-bridges { bridge-id: bridge-id }
             {
               identity: tx-sender,
               provider: provider,
               client-id-hash: client-id-hash,
               scope-permissions: scope-permissions,
               created-at: burn-block-height,
               last-used: u0,
               is-active: true
             })
    
    (var-set oauth-bridge-counter bridge-id)
    (ok bridge-id)
  )
)

;; Read-only Functions

(define-read-only (get-identity (identity-id principal))
  (map-get? identities { identity-id: identity-id })
)

(define-read-only (get-credential (credential-id uint))
  (map-get? credentials { credential-id: credential-id })
)

(define-read-only (get-verifier (verifier-id principal))
  (map-get? verifiers { verifier-id: verifier-id })
)

(define-read-only (get-recovery-guardian (identity principal) (guardian principal))
  (map-get? recovery-guardians { identity: identity, guardian: guardian })
)

(define-read-only (get-access-permissions (identity principal) (accessor principal))
  (map-get? access-permissions { identity: identity, accessor: accessor })
)

(define-read-only (is-identity-active (identity-id principal))
  (match (map-get? identities { identity-id: identity-id })
    identity-data (get is-active identity-data)
    false
  )
)

(define-read-only (is-credential-active (credential-id uint))
  (is-credential-valid credential-id)
)

(define-read-only (get-identity-reputation (identity-id principal))
  (match (map-get? identities { identity-id: identity-id })
    identity-data (calculate-reputation identity-data)
    u0
  )
)

(define-read-only (get-total-stats)
  {
    total-identities: (var-get total-identities),
    total-credentials: (var-get total-credentials),
    active-verifiers: (var-get verifier-counter)
  }
)

(define-read-only (get-analytics (metric-type (string-ascii 64)))
  (map-get? analytics-data { metric-type: metric-type })
)

(define-read-only (verify-access-permission (identity principal) (accessor principal) (permission-type (string-ascii 64)))
  (match (map-get? access-permissions { identity: identity, accessor: accessor })
    permission-data
    (and 
      (get is-active permission-data)
      (> (get expires-at permission-data) burn-block-height)
      (< (get usage-count permission-data) (get max-usage permission-data))
      (is-some (index-of (get permission-types permission-data) permission-type))
    )
    false
  )
)
