;; Water Usage Monitor Contract
;; IoT-based water consumption tracking with real-time usage verification
;; Ensures tamper-proof recording of usage data and compliance monitoring

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u100))
(define-constant ERR_NOT_AUTHORIZED (err u101))
(define-constant ERR_INVALID_METER (err u102))
(define-constant ERR_INVALID_USAGE (err u103))
(define-constant ERR_EXCEEDED_ALLOCATION (err u104))
(define-constant ERR_METER_DISABLED (err u105))
(define-constant ERR_INVALID_SENSOR (err u106))
(define-constant ERR_DUPLICATE_READING (err u107))
(define-constant ERR_FUTURE_TIMESTAMP (err u108))
(define-constant ERR_INVALID_CALIBRATION (err u109))

;; Maximum values for validation
(define-constant MAX_DAILY_ALLOCATION u1000000) ;; 1M gallons per day
(define-constant MAX_HOURLY_USAGE u50000)       ;; 50K gallons per hour
(define-constant CALIBRATION_THRESHOLD u95)     ;; 95% accuracy required

;; Data Maps and Variables
;; Water meter registration and management
(define-map water-meters
    { meter-id: (string-ascii 20) }
    {
        owner: principal,
        location: (string-ascii 100),
        installation-date: uint,
        status: (string-ascii 10), ;; "active", "inactive", "maintenance"
        daily-allocation: uint,
        total-capacity: uint,
        meter-type: (string-ascii 20)
    }
)

;; IoT sensor data and calibration
(define-map iot-sensors
    { sensor-id: (string-ascii 20) }
    {
        meter-id: (string-ascii 20),
        sensor-type: (string-ascii 30),
        calibration-date: uint,
        accuracy-rating: uint, ;; Percentage (0-100)
        firmware-version: (string-ascii 10),
        last-maintenance: uint,
        status: (string-ascii 10)
    }
)

;; Real-time usage readings from IoT devices
(define-map usage-readings
    { meter-id: (string-ascii 20), timestamp: uint }
    {
        sensor-id: (string-ascii 20),
        usage-amount: uint,
        reading-type: (string-ascii 15), ;; "hourly", "daily", "instant"
        verification-hash: (buff 32),
        temperature: uint,
        pressure: uint,
        flow-rate: uint
    }
)

;; Daily usage aggregates for compliance tracking
(define-map daily-usage
    { meter-id: (string-ascii 20), date: uint }
    {
        total-usage: uint,
        peak-hour-usage: uint,
        reading-count: uint,
        compliance-status: (string-ascii 15), ;; "compliant", "warning", "violation"
        last-updated: uint
    }
)

;; Historical usage patterns for analysis
(define-map usage-history
    { meter-id: (string-ascii 20), month: uint, year: uint }
    {
        monthly-usage: uint,
        average-daily: uint,
        peak-day-usage: uint,
        efficiency-score: uint,
        conservation-rate: uint
    }
)

;; Authorized IoT device principals
(define-map authorized-devices
    { device-address: principal }
    { authorized-by: principal, authorization-date: uint }
)

;; Compliance tracking and violation records
(define-map compliance-violations
    { meter-id: (string-ascii 20), violation-id: uint }
    {
        violation-type: (string-ascii 30),
        severity: (string-ascii 10), ;; "low", "medium", "high", "critical"
        detected-at: uint,
        usage-amount: uint,
        allocation-limit: uint,
        resolved: bool
    }
)

;; Counter for generating unique violation IDs
(define-data-var violation-counter uint u0)

;; Emergency shut-off triggers
(define-data-var emergency-mode bool false)

;; Private Functions
;; Calculate current date from burn block height
(define-private (get-current-date)
    (/ burn-block-height u144) ;; Approximate daily blocks
)

;; Validate sensor accuracy and calibration
(define-private (is-sensor-calibrated (sensor-id (string-ascii 20)))
    (match (map-get? iot-sensors { sensor-id: sensor-id })
        sensor-data
        (and 
            (>= (get accuracy-rating sensor-data) CALIBRATION_THRESHOLD)
            (< (- burn-block-height (get calibration-date sensor-data)) u5040) ;; Within 35 days
        )
        false
    )
)

;; Check if usage exceeds daily allocation
(define-private (check-allocation-compliance (meter-id (string-ascii 20)) (usage uint))
    (match (map-get? water-meters { meter-id: meter-id })
        meter-data
        (<= usage (get daily-allocation meter-data))
        false
    )
)

;; Generate verification hash for reading integrity
(define-private (generate-verification-hash (meter-id (string-ascii 20)) (usage uint) (timestamp uint))
    (sha256 (concat 
        (concat (unwrap-panic (to-consensus-buff? meter-id)) 
                (unwrap-panic (to-consensus-buff? usage)))
        (unwrap-panic (to-consensus-buff? timestamp))
    ))
)

;; Update daily usage aggregates
(define-private (update-daily-aggregate (meter-id (string-ascii 20)) (usage uint))
    (let (
        (current-date (get-current-date))
        (existing-data (default-to 
            { total-usage: u0, peak-hour-usage: u0, reading-count: u0, 
              compliance-status: "compliant", last-updated: u0 }
            (map-get? daily-usage { meter-id: meter-id, date: current-date })
        ))
    )
        (map-set daily-usage
            { meter-id: meter-id, date: current-date }
            {
                total-usage: (+ (get total-usage existing-data) usage),
                peak-hour-usage: (if (> usage (get peak-hour-usage existing-data)) 
                                   usage (get peak-hour-usage existing-data)),
                reading-count: (+ (get reading-count existing-data) u1),
                compliance-status: (if (check-allocation-compliance meter-id 
                                         (+ (get total-usage existing-data) usage))
                                     "compliant" "violation"),
                last-updated: burn-block-height
            }
        )
    )
)

;; Record compliance violation
(define-private (record-violation (meter-id (string-ascii 20)) (usage uint) (allocation uint))
    (let (
        (violation-id (var-get violation-counter))
    )
        (map-set compliance-violations
            { meter-id: meter-id, violation-id: violation-id }
            {
                violation-type: "allocation-exceeded",
                severity: (if (> usage (* allocation u2)) "critical" "high"),
                detected-at: burn-block-height,
                usage-amount: usage,
                allocation-limit: allocation,
                resolved: false
            }
        )
        (var-set violation-counter (+ violation-id u1))
    )
)

;; Public Functions
;; Register a new water meter with allocation limits
(define-public (register-meter (meter-id (string-ascii 20)) 
                              (owner principal) 
                              (location (string-ascii 100))
                              (daily-allocation uint)
                              (total-capacity uint)
                              (meter-type (string-ascii 20)))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        (asserts! (<= daily-allocation MAX_DAILY_ALLOCATION) ERR_INVALID_USAGE)
        
        (map-set water-meters
            { meter-id: meter-id }
            {
                owner: owner,
                location: location,
                installation-date: burn-block-height,
                status: "active",
                daily-allocation: daily-allocation,
                total-capacity: total-capacity,
                meter-type: meter-type
            }
        )
        (ok true)
    )
)

;; Register IoT sensor for a water meter
(define-public (register-sensor (sensor-id (string-ascii 20))
                               (meter-id (string-ascii 20))
                               (sensor-type (string-ascii 30))
                               (accuracy-rating uint)
                               (firmware-version (string-ascii 10)))
    (begin
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER) 
                     (is-some (map-get? authorized-devices { device-address: tx-sender })))
                 ERR_NOT_AUTHORIZED)
        (asserts! (is-some (map-get? water-meters { meter-id: meter-id })) ERR_INVALID_METER)
        (asserts! (<= accuracy-rating u100) ERR_INVALID_CALIBRATION)
        
        (map-set iot-sensors
            { sensor-id: sensor-id }
            {
                meter-id: meter-id,
                sensor-type: sensor-type,
                calibration-date: burn-block-height,
                accuracy-rating: accuracy-rating,
                firmware-version: firmware-version,
                last-maintenance: burn-block-height,
                status: "active"
            }
        )
        (ok true)
    )
)

;; Submit usage reading from IoT device
(define-public (submit-usage-reading (meter-id (string-ascii 20))
                                   (sensor-id (string-ascii 20))
                                   (usage-amount uint)
                                   (reading-type (string-ascii 15))
                                   (temperature uint)
                                   (pressure uint)
                                   (flow-rate uint))
    (let (
        (timestamp burn-block-height)
        (verification-hash (generate-verification-hash meter-id usage-amount timestamp))
    )
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER)
                     (is-some (map-get? authorized-devices { device-address: tx-sender })))
                 ERR_NOT_AUTHORIZED)
        (asserts! (is-some (map-get? water-meters { meter-id: meter-id })) ERR_INVALID_METER)
        (asserts! (is-some (map-get? iot-sensors { sensor-id: sensor-id })) ERR_INVALID_SENSOR)
        (asserts! (<= usage-amount MAX_HOURLY_USAGE) ERR_INVALID_USAGE)
        (asserts! (is-sensor-calibrated sensor-id) ERR_INVALID_CALIBRATION)
        (asserts! (is-none (map-get? usage-readings 
                           { meter-id: meter-id, timestamp: timestamp })) ERR_DUPLICATE_READING)
        
        ;; Record the usage reading
        (map-set usage-readings
            { meter-id: meter-id, timestamp: timestamp }
            {
                sensor-id: sensor-id,
                usage-amount: usage-amount,
                reading-type: reading-type,
                verification-hash: verification-hash,
                temperature: temperature,
                pressure: pressure,
                flow-rate: flow-rate
            }
        )
        
        ;; Update daily aggregates
        (update-daily-aggregate meter-id usage-amount)
        
        ;; Check compliance and record violations if necessary
        (match (map-get? water-meters { meter-id: meter-id })
            meter-data
            (if (not (check-allocation-compliance meter-id usage-amount))
                (record-violation meter-id usage-amount (get daily-allocation meter-data))
                true
            )
            true
        )
        
        (ok timestamp)
    )
)

;; Authorize IoT device for data submission
(define-public (authorize-device (device-address principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        
        (map-set authorized-devices
            { device-address: device-address }
            { authorized-by: tx-sender, authorization-date: burn-block-height }
        )
        (ok true)
    )
)

;; Get current daily usage for a meter
(define-read-only (get-daily-usage (meter-id (string-ascii 20)))
    (map-get? daily-usage { meter-id: meter-id, date: (get-current-date) })
)

;; Get meter information
(define-read-only (get-meter-info (meter-id (string-ascii 20)))
    (map-get? water-meters { meter-id: meter-id })
)

;; Get sensor information
(define-read-only (get-sensor-info (sensor-id (string-ascii 20)))
    (map-get? iot-sensors { sensor-id: sensor-id })
)

;; Get usage reading by timestamp
(define-read-only (get-usage-reading (meter-id (string-ascii 20)) (timestamp uint))
    (map-get? usage-readings { meter-id: meter-id, timestamp: timestamp })
)

;; Check if device is authorized
(define-read-only (is-device-authorized (device-address principal))
    (is-some (map-get? authorized-devices { device-address: device-address }))
)

;; Get compliance violations for a meter
(define-read-only (get-compliance-status (meter-id (string-ascii 20)))
    (map-get? daily-usage { meter-id: meter-id, date: (get-current-date) })
)

