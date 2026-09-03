class AddSecondTimeSlotToWorkingHours < ActiveRecord::Migration[7.1]
  def change
    add_column :working_hours, :open_hour_2, :integer
    add_column :working_hours, :open_minutes_2, :integer
    add_column :working_hours, :close_hour_2, :integer
    add_column :working_hours, :close_minutes_2, :integer
  end
end
