class User < ActiveRecord::Base
  include NonNullUuid
  include PhoneConfirmable
  include AuditEvents

  after_validation :set_default_role, if: :new_record?

  devise :confirmable, :database_authenticatable, :lockable, :recoverable,
         :registerable, :timeoutable, :trackable, :two_factor_authenticatable,
         :omniauthable, omniauth_providers: [:saml]

  enum ial: [:IA1, :IA2, :IA3, :IA4]
  enum role: { user: 0, tech: 1, admin: 2 }

  has_one_time_password

  validates :ial_token, uniqueness: true, allow_nil: true

  has_many :authorizations, dependent: :destroy
  has_many :identities, dependent: :destroy

  def set_default_role
    self.role ||= :user
  end

  def need_two_factor_authentication?(request)
    two_factor_enabled? && !third_party_authenticated?(request)
  end

  def third_party_authenticated?(request)
    request.env.key?('omniauth.auth') ? true : false
  end

  def two_factor_enabled?
    mobile_confirmed_at.present?
  end

  def send_two_factor_authentication_code
    UserOtpSender.new(self).send_otp
  end

  def confirmation_period_expired?
    confirmation_sent_at && confirmation_sent_at.utc <= self.class.confirm_within.ago
  end

  def send_reset_confirmation
    update(reset_requested_at: Time.current, confirmed_at: nil)
    send_confirmation_instructions
  end

  def second_factor_locked?
    max_login_attempts? && otp_time_lockout?
  end

  def otp_time_lockout?
    return false if second_factor_locked_at.nil?
    (Time.current - second_factor_locked_at) < Devise.allowed_otp_drift_seconds
  end

  def lock_access!(opts = {})
    super
    send_devise_notification(:unlock_instructions, nil, subject: 'Upaya Account Locked')
  end

  def identity_verified?
    ial == 'IA3'
  end

  def set_active_identity(entity_id, authn_context = nil, authenticated = nil)
    session_index = (active_identities.size || 0) + 1
    identity_opts = { authn_context: authn_context, session_index: session_index }

    identity = Identity.find_or_create_by(
      service_provider: entity_id,
      user_id: id
    )

    if authenticated == true
      identity_opts[:last_authenticated_at] = Time.current
      identity_opts[:session_uuid] = "_#{SecureRandom.uuid}"
    end

    identity if identity.update(identity_opts)
  end

  def first_identity
    active_identities[0] unless active_identities.empty?
  end

  def last_identity
    active_identities[-1] unless active_identities.empty?
  end

  def last_quizzed_identity
    identities.order(updated_at: :desc).detect(&:quiz_started)
  end

  def active_identities
    identities.where(
      'last_authenticated_at IS NOT ?',
      nil
    ).order(
      last_authenticated_at: :asc
    )
  end

  def multiple_identities?
    active_identities.size > 1
  end

  def needs_idv?
    ial_token.present? && !(identity_verified? || idp_hard_fail?)
  end

  # To send emails asynchronously via ActiveJob.
  def send_devise_notification(notification, *args)
    devise_mailer.send(notification, self, *args).deliver_later
  end
end
