package parser

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/example/hospital/internal/domain"
)

var ErrInvalidRecord = fmt.Errorf("invalid appointment record")

// AppointmentRow is the raw database row returned by the repository.
type AppointmentRow struct {
	ID           int
	PatientName  string
	DepartmentID int
	ScheduledAt  time.Time
	DurationMins int
	NotesJSON    []byte
	Cancelled    bool
}

// FromRecord maps a raw database row to a domain Appointment.
func FromRecord(row AppointmentRow) (*domain.Appointment, error) {
	if row.PatientName == "" {
		return nil, fmt.Errorf("%w: patient name is required", ErrInvalidRecord)
	}

	var notes []string
	if len(row.NotesJSON) > 0 {
		if err := json.Unmarshal(row.NotesJSON, &notes); err != nil {
			return nil, fmt.Errorf("%w: malformed notes JSON", ErrInvalidRecord)
		}
	}

	return &domain.Appointment{
		ID:           row.ID,
		PatientName:  row.PatientName,
		DepartmentID: row.DepartmentID,
		ScheduledAt:  row.ScheduledAt,
		DurationMins: row.DurationMins,
		Notes:        notes,
		Cancelled:    row.Cancelled,
	}, nil
}
