class Procedure < ApplicationRecord
  has_many :procedure_visibilities, dependent: :destroy
  has_many :procedure_targets, dependent: :destroy
  has_many :attachments, as: :attachable, dependent: :destroy

  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true

  enum :status, { draft: 0, published: 1, archived: 2 }
  enum :usage_mode, { internal: 0, customer: 1, both: 2 }

  validates :title, presence: true, length: { maximum: 255 }
  validates :description, length: { maximum: 2_000 }
  validates :category, length: { maximum: 120 }
  validate :content_blocks_is_array
  validate :tags_is_array

  scope :active, -> { where.not(status: :archived) }
  scope :search, lambda { |query|
    next all if query.blank?

    pattern = "%#{sanitize_sql_like(query)}%"
    where(
      'title ILIKE :query OR description ILIKE :query OR category ILIKE :query OR tags::text ILIKE :query OR content_blocks::text ILIKE :query',
      query: pattern
    )
  }

  def self.visible_to(user, management: false)
    return all if management || user&.administrator?

    team_ids = user&.teams&.pluck(:id) || []
    inbox_ids = user&.assigned_inboxes&.pluck(:id) || []

    left_joins(:procedure_visibilities)
      .published
      .where(
        <<~SQL.squish,
          procedure_visibilities.scope_type = 'all'
          OR (procedure_visibilities.scope_type = 'team' AND procedure_visibilities.scope_id IN (:team_ids))
          OR (procedure_visibilities.scope_type = 'inbox' AND procedure_visibilities.scope_id IN (:inbox_ids))
        SQL
        team_ids: team_ids.presence || [nil],
        inbox_ids: inbox_ids.presence || [nil]
      ).distinct
  end

  def publish!
    update!(status: :published, published_at: published_at || Time.current)
  end

  def archive!
    update!(status: :archived, archived_at: Time.current)
  end

  def customer_shareable?
    customer? || both?
  end

  private

  def content_blocks_is_array
    errors.add(:content_blocks, 'must be an array') unless content_blocks.is_a?(Array)
  end

  def tags_is_array
    errors.add(:tags, 'must be an array') unless tags.is_a?(Array)
  end
end
