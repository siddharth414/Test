# Convert to DataFrames
transaction_df = pd.DataFrame(transaction_data)
loan_df = pd.DataFrame(loan_data)

# Function to get matched records
def get_matched_records(transaction_df, loan_df):
    matched_records = []

    for _, trans_row in transaction_df.iterrows():
        name = trans_row['obligor_name_matched']
        type_code = trans_row['obligation_type_code']

        # Filter loan_df for this name and type code
        matches = loan_df[
            (loan_df['name'] == name) &
            (loan_df['obligation_type_code'] == type_code)
        ]

        # If exactly one match, add this transaction row
        if len(matches) == 1:
            matched_records.append(trans_row)

    return pd.DataFrame(matched_records)

# Run the function
matched_df = get_matched_records(transaction_df, loan_df)
