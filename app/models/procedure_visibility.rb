class ProcedureVisibility < ApplicationRecord
  SCOPE_TYPES = %w[all team inbox public_link].freeze

  belongs_to :procedure

  validates :scope_type, presence: true, inclusion: { in: SCOPE_TYPES }
  validates :scope_id, presence: true, if: -> { scope_type.in?(%w[team inbox]) }
  validates :scope_id, absence: true, if: -> { scope_type.in?(%w[all public_link]) }
  validates :scope_type, uniqueness: { scope: [:procedure_id, :scope_id] }
end
