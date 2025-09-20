;; Conservation Reward System Contract
;; Automated rewards for water conservation and efficient usage practices
;; Calculates conservation scores and distributes incentive tokens

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u200))
(define-constant ERR_NOT_AUTHORIZED (err u201))
(define-constant ERR_INVALID_USER (err u202))
(define-constant ERR_INVALID_AMOUNT (err u203))
(define-constant ERR_INSUFFICIENT_BALANCE (err u204))
(define-constant ERR_INVALID_GOAL (err u205))
(define-constant ERR_GOAL_NOT_FOUND (err u206))
(define-constant ERR_CHALLENGE_ENDED (err u207))
(define-constant ERR_ALREADY_PARTICIPATING (err u208))
(define-constant ERR_REWARD_NOT_AVAILABLE (err u209))
(define-constant ERR_INVALID_TIER (err u210))

;; Conservation reward parameters
(define-constant BASE_REWARD_RATE u100)      ;; Base tokens per gallon saved
(define-constant EFFICIENCY_MULTIPLIER u150) ;; 1.5x for high efficiency
(define-constant COMMUNITY_BONUS u200)       ;; 2x for community challenges
(define-constant MIN_SAVINGS_THRESHOLD u50)  ;; Minimum gallons to qualify
(define-constant MAX_DAILY_REWARDS u10000)   ;; Maximum tokens per day

;; Conservation tiers and thresholds
(define-constant BRONZE_THRESHOLD u100)   ;; 100 gallons saved
(define-constant SILVER_THRESHOLD u500)   ;; 500 gallons saved
(define-constant GOLD_THRESHOLD u1000)    ;; 1000 gallons saved
(define-constant PLATINUM_THRESHOLD u5000) ;; 5000 gallons saved

;; Token definitions
(define-fungible-token conservation-token)

;; Data Maps and Variables
;; User profiles and conservation history
(define-map user-profiles
    { user-address: principal }
    {
        total-rewards-earned: uint,
        conservation-level: (string-ascii 15), ;; "bronze", "silver", "gold", "platinum"
        total-water-saved: uint,
        efficiency-score: uint, ;; 0-100 percentage
        streak-days: uint,
        last-activity: uint,
        preferred-goals: (list 3 (string-ascii 20))
    }
)

;; Conservation goals and targets
(define-map conservation-goals
    { goal-id: uint }
    {
        creator: principal,
        title: (string-ascii 50),
        description: (string-ascii 200),
        target-savings: uint,
        duration-blocks: uint,
        reward-pool: uint,
        participants: uint,
        start-block: uint,
        end-block: uint,
        goal-type: (string-ascii 20), ;; "personal", "community", "challenge"
        status: (string-ascii 15) ;; "active", "completed", "cancelled"
    }
)

;; User participation in goals
(define-map goal-participants
    { goal-id: uint, participant: principal }
    {
        joined-at: uint,
        progress: uint,
        personal-target: uint,
        completed: bool,
        reward-claimed: bool
    }
)

;; Daily conservation metrics
(define-map daily-conservation
    { user-address: principal, date: uint }
    {
        water-saved: uint,
        efficiency-rating: uint,
        baseline-usage: uint,
        actual-usage: uint,
        conservation-actions: (list 5 (string-ascii 30)),
        rewards-earned: uint,
        verified: bool
    }
)

;; Conservation achievements and badges
(define-map achievements
    { achievement-id: uint }
    {
        name: (string-ascii 30),
        description: (string-ascii 100),
        requirement-type: (string-ascii 20), ;; "savings", "streak", "efficiency"
        requirement-value: uint,
        reward-amount: uint,
        icon: (string-ascii 20),
        rarity: (string-ascii 10) ;; "common", "rare", "epic", "legendary"
    }
)

;; User achievement progress
(define-map user-achievements
    { user-address: principal, achievement-id: uint }
    {
        progress: uint,
        completed: bool,
        completed-at: uint,
        reward-claimed: bool
    }
)

;; Community challenges
(define-map community-challenges
    { challenge-id: uint }
    {
        name: (string-ascii 40),
        description: (string-ascii 150),
        start-block: uint,
        end-block: uint,
        target-participants: uint,
        current-participants: uint,
        total-reward-pool: uint,
        leaderboard-rewards: (list 10 uint),
        challenge-type: (string-ascii 20), ;; "savings", "efficiency", "streak"
        status: (string-ascii 15)
    }
)

;; Reward distribution history
(define-map reward-history
    { user-address: principal, timestamp: uint }
    {
        amount: uint,
        reason: (string-ascii 50),
        goal-id: (optional uint),
        achievement-id: (optional uint),
        multiplier-applied: uint,
        transaction-hash: (optional (buff 32))
    }
)

;; System counters
(define-data-var goal-counter uint u0)
(define-data-var achievement-counter uint u0)
(define-data-var challenge-counter uint u0)

;; Reward pool management
(define-data-var total-reward-pool uint u0)
(define-data-var daily-reward-budget uint u50000)
(define-data-var rewards-distributed-today uint u0)
(define-data-var last-reset-date uint u0)

;; Private Functions
;; Calculate current date from burn block height
(define-private (get-current-date)
    (/ burn-block-height u144) ;; Approximate daily blocks
)

;; Calculate conservation efficiency score
(define-private (calculate-efficiency-score (baseline uint) (actual uint))
    (if (and (> baseline u0) (< actual baseline))
        (let (
            (savings (- baseline actual))
            (efficiency-percent (/ (* savings u100) baseline))
        )
            (if (> efficiency-percent u100) u100 efficiency-percent)
        )
        u0
    )
)

;; Determine conservation level based on total savings
(define-private (get-conservation-level (total-saved uint))
    (if (>= total-saved PLATINUM_THRESHOLD)
        "platinum"
        (if (>= total-saved GOLD_THRESHOLD)
            "gold"
            (if (>= total-saved SILVER_THRESHOLD)
                "silver"
                "bronze"
            )
        )
    )
)

;; Calculate reward multiplier based on user level
(define-private (get-level-multiplier (level (string-ascii 15)))
    (if (is-eq level "platinum")
        u300 ;; 3x multiplier
        (if (is-eq level "gold")
            u250 ;; 2.5x multiplier
            (if (is-eq level "silver")
                u200 ;; 2x multiplier
                u150 ;; 1.5x multiplier for bronze
            )
        )
    )
)

;; Calculate base rewards for conservation
(define-private (calculate-base-rewards (water-saved uint) (efficiency uint))
    (let (
        (base-amount (* water-saved BASE_REWARD_RATE))
        (efficiency-bonus (if (> efficiency u80) (* base-amount EFFICIENCY_MULTIPLIER) u0))
    )
        (+ base-amount efficiency-bonus)
    )
)

;; Update user conservation streak
(define-private (update-conservation-streak (user principal) (current-date uint))
    (let (
        (profile (default-to
            { total-rewards-earned: u0, conservation-level: "bronze", 
              total-water-saved: u0, efficiency-score: u0, 
              streak-days: u0, last-activity: u0, preferred-goals: (list) }
            (map-get? user-profiles { user-address: user })
        ))
        (last-date (/ (get last-activity profile) u144))
    )
        (if (is-eq (- current-date last-date) u1)
            ;; Consecutive day - increment streak
            (+ (get streak-days profile) u1)
            ;; Reset streak if gap > 1 day
            (if (> (- current-date last-date) u1) u1 (get streak-days profile))
        )
    )
)

;; Distribute achievement rewards
(define-private (distribute-achievement-reward (user principal) (achievement-id uint))
    (match (map-get? achievements { achievement-id: achievement-id })
        achievement-data
        (let (
            (reward-amount (get reward-amount achievement-data))
        )
            (unwrap-panic (ft-mint? conservation-token reward-amount user))
        )
        false
    )
)

;; Check and update achievements
(define-private (check-achievements (user principal) (water-saved uint) (streak uint) (efficiency uint))
    (let (
        (savings-achievements (list u1 u2 u3)) ;; Achievement IDs for savings milestones
        (streak-achievements (list u4 u5 u6))  ;; Achievement IDs for streak milestones
        (efficiency-achievements (list u7 u8))  ;; Achievement IDs for efficiency milestones
    )
        ;; Check each achievement type - simplified for demo
        (map check-single-achievement savings-achievements)
        true
    )
)

;; Helper function to check individual achievement
(define-private (check-single-achievement (achievement-id uint))
    (match (map-get? achievements { achievement-id: achievement-id })
        achievement-data true
        false
    )
)

;; Public Functions
;; Initialize user profile
(define-public (initialize-user-profile (preferred-goals (list 3 (string-ascii 20))))
    (begin
        (map-set user-profiles
            { user-address: tx-sender }
            {
                total-rewards-earned: u0,
                conservation-level: "bronze",
                total-water-saved: u0,
                efficiency-score: u0,
                streak-days: u0,
                last-activity: burn-block-height,
                preferred-goals: preferred-goals
            }
        )
        (ok true)
    )
)

;; Record daily conservation activity
(define-public (record-conservation (water-saved uint) 
                                  (baseline-usage uint) 
                                  (actual-usage uint)
                                  (conservation-actions (list 5 (string-ascii 30))))
    (let (
        (current-date (get-current-date))
        (efficiency (calculate-efficiency-score baseline-usage actual-usage))
        (base-rewards (calculate-base-rewards water-saved efficiency))
        (profile (default-to
            { total-rewards-earned: u0, conservation-level: "bronze", 
              total-water-saved: u0, efficiency-score: u0, 
              streak-days: u0, last-activity: u0, preferred-goals: (list) }
            (map-get? user-profiles { user-address: tx-sender })
        ))
        (level-multiplier (get-level-multiplier (get conservation-level profile)))
        (final-rewards (/ (* base-rewards level-multiplier) u100))
        (streak (update-conservation-streak tx-sender current-date))
    )
        (asserts! (> water-saved MIN_SAVINGS_THRESHOLD) ERR_INVALID_AMOUNT)
        (asserts! (<= final-rewards MAX_DAILY_REWARDS) ERR_INVALID_AMOUNT)
        
        ;; Record daily conservation data
        (map-set daily-conservation
            { user-address: tx-sender, date: current-date }
            {
                water-saved: water-saved,
                efficiency-rating: efficiency,
                baseline-usage: baseline-usage,
                actual-usage: actual-usage,
                conservation-actions: conservation-actions,
                rewards-earned: final-rewards,
                verified: false
            }
        )
        
        ;; Update user profile
        (map-set user-profiles
            { user-address: tx-sender }
            {
                total-rewards-earned: (+ (get total-rewards-earned profile) final-rewards),
                conservation-level: (get-conservation-level 
                    (+ (get total-water-saved profile) water-saved)),
                total-water-saved: (+ (get total-water-saved profile) water-saved),
                efficiency-score: (/ (+ (get efficiency-score profile) efficiency) u2),
                streak-days: streak,
                last-activity: burn-block-height,
                preferred-goals: (get preferred-goals profile)
            }
        )
        
        ;; Mint rewards
        (try! (ft-mint? conservation-token final-rewards tx-sender))
        
        ;; Record reward history
        (map-set reward-history
            { user-address: tx-sender, timestamp: burn-block-height }
            {
                amount: final-rewards,
                reason: "daily-conservation",
                goal-id: none,
                achievement-id: none,
                multiplier-applied: level-multiplier,
                transaction-hash: none
            }
        )
        
        ;; Check for achievements
        (check-achievements tx-sender water-saved streak efficiency)
        
        (ok final-rewards)
    )
)

;; Create conservation goal
(define-public (create-conservation-goal (title (string-ascii 50))
                                       (description (string-ascii 200))
                                       (target-savings uint)
                                       (duration-blocks uint)
                                       (reward-pool uint)
                                       (goal-type (string-ascii 20)))
    (let (
        (goal-id (var-get goal-counter))
        (end-block (+ burn-block-height duration-blocks))
    )
        (asserts! (> target-savings u0) ERR_INVALID_GOAL)
        (asserts! (> duration-blocks u0) ERR_INVALID_GOAL)
        (asserts! (> reward-pool u0) ERR_INVALID_AMOUNT)
        
        (map-set conservation-goals
            { goal-id: goal-id }
            {
                creator: tx-sender,
                title: title,
                description: description,
                target-savings: target-savings,
                duration-blocks: duration-blocks,
                reward-pool: reward-pool,
                participants: u0,
                start-block: burn-block-height,
                end-block: end-block,
                goal-type: goal-type,
                status: "active"
            }
        )
        
        (var-set goal-counter (+ goal-id u1))
        (ok goal-id)
    )
)

;; Join conservation goal
(define-public (join-conservation-goal (goal-id uint) (personal-target uint))
    (begin
        (asserts! (is-some (map-get? conservation-goals { goal-id: goal-id })) ERR_GOAL_NOT_FOUND)
        (asserts! (is-none (map-get? goal-participants 
                           { goal-id: goal-id, participant: tx-sender })) ERR_ALREADY_PARTICIPATING)
        
        (map-set goal-participants
            { goal-id: goal-id, participant: tx-sender }
            {
                joined-at: burn-block-height,
                progress: u0,
                personal-target: personal-target,
                completed: false,
                reward-claimed: false
            }
        )
        
        ;; Update goal participant count
        (match (map-get? conservation-goals { goal-id: goal-id })
            goal-data
            (map-set conservation-goals
                { goal-id: goal-id }
                (merge goal-data { participants: (+ (get participants goal-data) u1) })
            )
            false
        )
        
        (ok true)
    )
)

;; Get user profile
(define-read-only (get-user-profile (user principal))
    (map-get? user-profiles { user-address: user })
)

;; Get daily conservation data
(define-read-only (get-daily-conservation (user principal) (date uint))
    (map-get? daily-conservation { user-address: user, date: date })
)

;; Get conservation goal details
(define-read-only (get-conservation-goal (goal-id uint))
    (map-get? conservation-goals { goal-id: goal-id })
)

;; Get user's token balance
(define-read-only (get-balance (user principal))
    (ft-get-balance conservation-token user)
)

;; Get total token supply
(define-read-only (get-total-supply)
    (ft-get-supply conservation-token)
)

;; Get user's participation in a goal
(define-read-only (get-goal-participation (goal-id uint) (user principal))
    (map-get? goal-participants { goal-id: goal-id, participant: user })
)

;; Calculate potential rewards for given conservation
(define-read-only (calculate-potential-rewards (water-saved uint) (efficiency uint) (user principal))
    (let (
        (profile (map-get? user-profiles { user-address: user }))
    )
        (match profile
            user-data
            (let (
                (base-amount (calculate-base-rewards water-saved efficiency))
                (multiplier (get-level-multiplier (get conservation-level user-data)))
            )
                (/ (* base-amount multiplier) u100)
            )
            (calculate-base-rewards water-saved efficiency)
        )
    )
)

