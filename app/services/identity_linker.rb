IdentityLinker = Struct.new(:user, :provider) do
  attr_reader :identity

  def link_identity
    find_or_create_identity

    identity.update!(identity_attributes)
  end

  private

  def find_or_create_identity
    @identity = Identity.find_or_create_by(
      service_provider: provider,
      user_id: user.id
    )
  end

  def identity_attributes
    {
      last_authenticated_at: Time.current,
      session_uuid: SecureRandom.uuid
    }
  end
end
